module Bouncefetch
  class Application
    class Rules < Configuration
      alias_method :type, :setup

      def crosschecks &block
        setup :crosschecks, &block
      end

      def rule condition = nil, crosscheck = true, &block
        @current_store[:rules] ||= []
        @current_store[:rules].unshift Rule.new(block || condition, crosscheck)
      end
    end
  end
end
