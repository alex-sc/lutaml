require "nokogiri"
require "htmlentities"
require "lutaml/uml/has_attributes"
require "lutaml/uml/document"
require "lutaml/xmi"

module Lutaml
  module XMI
    module Parsers
      # Class for parsing .xmi schema files into ::Lutaml::Uml::Document
      class XML
        LOWER_VALUE_MAPPINGS = {
          "0" => "C",
          "1" => "M",
        }.freeze
        attr_reader :main_model, :xmi_cache, :xmi_root_model

        # @param xml [String] path to xml
        # @param options [Hash] options for parsing
        # @return [Lutaml::Uml::Document]
        def self.parse(xml, _options = {})
          xml_content = File.read(xml)
          xmi_model = Xmi::Sparx::SparxRoot.from_xml(xml_content)
          xmi_doc = Nokogiri::XML(File.open(xml).read)
          new.parse(xmi_model, xmi_doc)
        end

        def parse(xmi_model, xmi_doc)
          @xmi_cache = {}
          @xmi_root_model = xmi_model
          @main_model = xmi_doc
          ::Lutaml::Uml::Document
            .new(serialize_to_hash(xmi_model))
        end

        private

        # @note xpath: //uml:Model[@xmi:type="uml:Model"]
        def serialize_to_hash(xmi_doc)
          model = xmi_doc.model
          {
            name: model.name,
            packages: serialize_model_packages(model)
          }
        end

        # @note xpath ./packagedElement[@xmi:type="uml:Package"]
        def serialize_model_packages(model)
          model.packaged_element.map do |package|
            {
              xmi_id: package.id,
              name: package.name,
              classes: serialize_model_classes(package, model),
              enums: serialize_model_enums(package),
              data_types: serialize_model_data_types(package),
              diagrams: serialize_model_diagrams(package),
              packages: serialize_model_packages(package),
              definition: doc_node_attribute_value(package, "documentation"),
              stereotype: doc_node_attribute_value(package, "stereotype")
            }
          end
        end

        # @note xpath ./packagedElement[@xmi:type="uml:Class" or
        #                               @xmi:type="uml:AssociationClass"]
        def serialize_model_classes(package, model)
          package.packaged_element.select { |e|
            e.is_type?("uml:Class") || e.is_type?("uml:AssociationClass")
          }.map do |klass|
              {
                xmi_id: klass.id,
                # xmi_uuid: klass.uuid,
                name: klass.name,
                package: model,
                attributes: serialize_class_attributes(klass),
                associations: serialize_model_associations(klass),
                operations: serialize_class_operations(klass),
                constraints: serialize_class_constraints(klass),
                is_abstract: doc_node_attribute_value(klass, "isAbstract"),
                definition: doc_node_attribute_value(klass, "documentation"),
                stereotype: doc_node_attribute_value(klass, "stereotype")
              }
          end
        end

        # @note xpath ./packagedElement[@xmi:type="uml:Enumeration"]
        def serialize_model_enums(package)
          package.packaged_element
            .select { |e| e.is_type?("uml:Enumeration") }.map do |enum|
              # xpath .//ownedLiteral[@xmi:type="uml:EnumerationLiteral"]
              owned_literals = enum.owned_literal.map do |owned_literal|
                owned_literal.to_hash.transform_keys(&:to_sym)
              end
            {
              xmi_id: enum.id,
              name: enum.name,
              values: owned_literals,
              definition: doc_node_attribute_value(enum, "documentation"),
              stereotype: doc_node_attribute_value(enum, "stereotype"),
            }
          end
        end

        # @note xpath ./packagedElement[@xmi:type="uml:DataType"]
        def serialize_model_data_types(model)
          select_all_packaged_elements(model, "uml:DataType").map do |klass|
            {
              xmi_id: klass.id,
              name: klass.name,
              attributes: serialize_class_attributes(klass),
              operations: serialize_class_operations(klass),
              associations: serialize_model_associations(klass),
              constraints: serialize_class_constraints(klass),
              is_abstract: doc_node_attribute_value(klass, "isAbstract"),
              definition: doc_node_attribute_value(klass, "documentation"),
              stereotype: doc_node_attribute_value(klass, "stereotype"),
            }
          end
        end

        def serialize_model_diagrams(node)
          main_model.xpath(%(//diagrams/diagram/model[@package="#{node['xmi:id']}"])).map do |diagram_model|
            diagram = diagram_model.parent
            properties = diagram.children.find {|n| n.name == 'properties' }
            {
              xmi_id: diagram["xmi:id"],
              name: properties["name"],
              definition: properties.attributes['documentation']&.value
            }
          end
        end

        # @note xpath %(//element[@xmi:idref="#{xmi_id}"]/links/*)
        def serialize_model_associations(klass)
          xmi_id = klass.id
          matched_element = xmi_root_model.extension.elements.element
            .select { |e| e.idref == xmi_id }.first

          matched_element.links.map do |link|
            link.associations.map do |assoc|
              link_member_name = assoc.start == xmi_id ? "end" : "start"
              linke_owner_name = link_member_name == "start" ? "end" : "start"
              member_end, member_end_type, member_end_cardinality, member_end_attribute_name, member_end_xmi_id = serialize_member_type(xmi_id, link, link_member_name)
              owner_end, owner_end_cardinality, owner_end_attribute_name = serialize_owned_type(xmi_id, link, linke_owner_name)

              if member_end && ((member_end_type != 'aggregation') ||
                (member_end_type == 'aggregation' && member_end_attribute_name))

                doc_node_name = (link_member_name == "start" ?
                  "source" : "target")
                definition = fetch_definition_node_value(link.id, doc_node_name)
                {
                  xmi_id: link.id,
                  member_end: member_end,
                  member_end_type: member_end_type,
                  member_end_cardinality: member_end_cardinality,
                  member_end_attribute_name: member_end_attribute_name,
                  member_end_xmi_id: member_end_xmi_id,
                  owner_end: owner_end,
                  owner_end_xmi_id: xmi_id,
                  definition: definition
                }
              end
            end.uniq
          end
        end

        def fetch_definition_node_value(link_id, doc_node_name)
          definition_node = main_model
            .xpath(%(//connector[@xmi:idref="#{link.id}"]/#{doc_node_name}/documentation)).first

          definition_node.attributes['value']&.value if definition_node
        end

        # @note xpath .//ownedOperation
        def serialize_class_operations(klass)
          klass.owned_operation.map do |operation|
            uml_type = operation.uml_type.first || {}

            if operation.association.nil?
              {
                id: operation.id,
                xmi_id: uml_type.idref,
                name: operation.name,
                definition: lookup_attribute_documentation(operation.id),
              }
            end
          end.compact
        end

        def serialize_class_constraints(klass)
          class_element_metadata(klass).xpath("./constraints/constraint").map do |constraint|
            {
              xmi_id: constraint["xmi:id"],
              body: constraint["name"],
              definition: HTMLEntities.new.decode(constraint["description"])
            }
          end
        end

        def serialize_owned_type(owner_xmi_id, link, linke_owner_name)
          return if link.name == 'NoteLink'
          return generalization_association(owner_xmi_id, link) if link.name == "Generalization"

          xmi_id = link.send(linke_owner_name.to_sym)
          owner_end = lookup_entity_name(xmi_id) || connector_source_name(xmi_id)

          if link.name == "Association"
            owned_cardinality, owned_attribute_name =
              fetch_connector(link.id, "source")
          else
            owned_cardinality, owned_attribute_name =
              fetch_owned_attribute_node(xmi_id)
          end

          [owner_end, owned_cardinality, owned_attribute_name]
        end

        def serialize_member_type(owner_xmi_id, link, link_member_name)
          return if link.name == 'NoteLink'
          return generalization_association(owner_xmi_id, link) if link.name == "Generalization"

          xmi_id = link.send(link_member_name.to_sym)
          if link.start == owner_xmi_id
            xmi_id = link.end
            member_end = lookup_entity_name(xmi_id) || connector_target_name(xmi_id)
          else
            xmi_id = link.start
            member_end = lookup_entity_name(xmi_id) || connector_source_name(xmi_id)
          end

          if link.name == "Association"
            connector_type = link_member_name == "start" ? "source" : "target"
            member_end_cardinality, member_end_attribute_name =
              fetch_connector(link.id, connector_type)
          else
            member_end_cardinality, member_end_attribute_name =
              fetch_owned_attribute_node(xmi_id)
          end

          [member_end, "aggregation", member_end_cardinality,
            member_end_attribute_name, xmi_id]
        end

        # @note xpath %(//connector[@xmi:idref="#{link_id}"]/#{connector_type})
        def fetch_connector(link_id, connector_type)
          assoc_connector = main_model
            .xpath(%(//connector[@xmi:idref="#{link_id}"]/#{connector_type}))
            .first

          if assoc_connector
            connector_type = assoc_connector.children
              .find { |node| node.name == 'type' }
            if connector_type && connector_type.attributes['multiplicity']
              cardinality = connector_type
                .attributes['multiplicity']&.value&.split('..')
              cardinality.unshift('1') if cardinality.length == 1
              min, max = cardinality
            end
            connector_role = assoc_connector.children
              .find { |node| node.name == 'role' }
            if connector_role
              attribute_name = connector_role.attributes["name"]&.value
            end
            cardinality = { "min" => LOWER_VALUE_MAPPINGS[min], "max" => max }
          end

          return cardinality, attribute_name
        end

        def generalization_association(owner_xmi_id, link)
          if link.start == owner_xmi_id
            xmi_id = link.end
            member_end_type = "inheritance"
            member_end = lookup_entity_name(xmi_id) ||
              connector_target_name(xmi_id)
          else
            xmi_id = link.start
            member_end_type = "generalization"
            member_end = lookup_entity_name(xmi_id) ||
              connector_source_name(xmi_id)
          end

          member_end_cardinality, member_end_attribute_name =
            fetch_owned_attribute_node(xmi_id)

          [member_end, member_end_type, member_end_cardinality, nil, xmi_id]
        end

        # @note xpath
        #   %(//ownedAttribute[@association]/type[@xmi:idref="#{xmi_id}"])
        def fetch_owned_attribute_node(xmi_id)
          node = main_model.xpath(%(//ownedAttribute[@association]/type[@xmi:idref="#{xmi_id}"])).first
          if node
            assoc = node.parent

            upper_value_node = assoc.xpath(".//upperValue").first
            upper_value = upper_value_node.nil? ? nil : upper_value_node.attributes["value"]&.value

            lower_value_node = assoc.xpath(".//lowerValue").first
            lower_value = lower_value_node.nil? ? nil : lower_value_node.attributes["value"]&.value

            cardinality = {
              "min" => cardinality_min_value(lower_value),
              "max" => cardinality_max_value(upper_value)
            }

            assoc_name = assoc.attributes["name"]&.value
          end

          return cardinality, assoc_name
        end

        def class_element_metadata(klass)
          main_model.xpath(%(//element[@xmi:idref="#{klass['xmi:id']}"]))
        end

        # @note xpath .//ownedAttribute[@xmi:type="uml:Property"]
        def serialize_class_attributes(klass)
          klass.owned_attribute.select { |attr| attr.is_type?("uml:Property") }
            .map do |attribute|
              uml_type = attribute.uml_type.first || {}

              if attribute.association.nil?
                {
                  id: attribute.id,
                  name: attribute.name,
                  type: lookup_entity_name(uml_type.idref) || uml_type.idref,
                  xmi_id: uml_type.idref,
                  is_derived: attribute.is_derived,
                  cardinality: {
                    "min" => cardinality_min_value(attribute.lowerValue.value),
                    "max" => cardinality_max_value(attribute.upperValue.value)
                  },
                  definition: lookup_attribute_documentation(attribute.id),
                }
              end
          end.compact
        end

        def cardinality_min_value(value)
          return unless value

          LOWER_VALUE_MAPPINGS[value]
        end

        def cardinality_max_value(value)
          return unless value

          value
        end

        def doc_node_attribute_value(node, attr_name)
          xmi_id = node.id
          doc_node = main_model.xpath(%(//element[@xmi:idref="#{xmi_id}"]/properties)).first
          return unless doc_node

          doc_node.attributes[attr_name]&.value
        end

        def lookup_attribute_documentation(xmi_id)
          doc_node = main_model.xpath(%(//attribute[@xmi:idref="#{xmi_id}"]/documentation)).first
          return unless doc_node

          doc_node.attributes["value"]&.value
        end

        def lookup_entity_name(xmi_id)
          xmi_cache[xmi_id] ||= model_node_name_by_xmi_id(xmi_id)
          xmi_cache[xmi_id]
        end

        def connector_source_name(xmi_id)
          node = main_model.xpath(%(//source[@xmi:idref="#{xmi_id}"]/model)).first
          return unless node

          node.attributes["name"]&.value
        end

        def connector_target_name(xmi_id)
          node = main_model.xpath(%(//target[@xmi:idref="#{xmi_id}"]/model)).first
          return unless node

          node.attributes["name"]&.value
        end

        def model_node_name_by_xmi_id(xmi_id)
          node = main_model.xpath(%(//*[@xmi:id="#{xmi_id}"])).first
          return unless node

          node.attributes["name"]&.value
        end

        # @param type
        # @return [Array]
        # @note xpath ./packagedElement[@xmi:type="#{type}"]
        def select_all_packaged_elements(model, type)
          selected_elements = []
          iterate_tree(selected_elements, model, type, :packaged_element)
          selected_elements
        end

        # @param result [Array]
        # @param node [Object]
        # @param type [String]
        # @param children_method [String] method to determine children exist
        def iterate_tree(result, node, type, children_method)
          if node.type == type
            result << node
          end

          return unless node.send(children_method.to_sym)

          node.send(children_method.to_sym).each do |sub_node|
            if sub_node.send(children_method.to_sym)
              iterate_tree(result, sub_node, type, children_method)
            elsif sub_node.type == type
              result << sub_node
            end
          end
        end
      end
    end
  end
end
