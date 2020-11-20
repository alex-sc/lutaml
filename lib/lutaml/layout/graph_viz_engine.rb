# frozen_string_literal: true

require "ruby-graphviz"
require "lutaml/layout/engine"

module Lutaml
  module Layout
    class GraphVizEngine < Engine
      def render(type)
        Open3.popen3("dot -T#{type}") do |stdin, stdout, _stderr, _wait|
          stdin.puts(input)
          stdin.close
          # unless (err = stderr.read).empty? then raise err end
          stdout.read
        end
      end
    end
  end
end
