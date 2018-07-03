class Debouncer
  module Debounceable
    SUFFIXES = {
        '?' => '_predicate',
        '!' => '_dangerous',
        '=' => '_assignment'
    }
    def debounce(name, delay, opts)
      rescue_with = opts.fetch(:rescue_with, nil)
      grouped = opts.fetch(:grouped, nil)
      reduce_with = opts.fetch(:reduce_with, nil)
      class_method = opts.fetch(:class_method, nil)

      name =~ /^(\w+)([?!=]?)$/ or
          raise ArgumentError, 'Invalid method name'

      base_name = $1
      suffix    = $2
      immediate = "#{base_name}_immediately#{suffix}"
      debouncer = "@#{base_name}#{SUFFIXES[suffix]}_debouncer"
      extras    = ''
      if reduce_with
        arity    = __send__(class_method ? :method : :instance_method, reduce_with).arity
        expected = grouped ? 2..3 : 2
        unless arity < 0 || expected === arity
          raise ArgumentError, 'Expected %s%s%s to accept %s arguments, but it accepts %s.' %
              [self.name, class_method ? '.' : '#', reduce_with, expected, arity]
        end
        if grouped
          extras << ".reducer { |old, new| [new.first, *self.#{reduce_with}(old[1..-1] || [], new[1..-1]#{', new.first' unless arity == 2})] }"
        else
          extras << ".reducer { |old, new| self.#{reduce_with} old, new }"
        end
      end
      extras    << ".rescuer { |ex| self.#{rescue_with} ex }" if rescue_with

      class_eval <<-RUBY, __FILE__, __LINE__ + 1
        #{'class << self' if class_method}
      
        alias_method :#{immediate}, :#{name}

        def #{name}(*args, &block)
          #{debouncer} ||= ::Debouncer.new(#{delay}) { |*args| self.#{immediate} *args }#{extras}
          #{debouncer}#{'.group(args.first)' if grouped}.call *args, &block
        end

        def flush_#{name}(*args)
          #{debouncer}.flush *args if #{debouncer}
        end

        def flush_and_join_#{name}(*args)
          #{debouncer}.flush! *args if #{debouncer}
        end

        def join_#{name}(*args)
          #{debouncer}.join *args if #{debouncer}
        end

        def cancel_#{name}(*args)
          #{debouncer}.kill *args if #{debouncer}
        end

        #{'end' if class_method}
      RUBY
    end

    def mdebounce(name, delay, opts)
      debounce name, delay, opts.merge({class_method: true})
    end
  end
end
