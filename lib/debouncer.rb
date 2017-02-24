require 'debouncer/version'

class Debouncer
  def initialize(delay, &block)
    raise ArgumentError, 'Expected a number' unless delay.is_a? Numeric
    @delay    = delay
    @timeouts = {}
    @threads  = []
    @lock     = Mutex.new
    @rescuers = {}
    block.arity.zero? ? instance_exec(&block) : yield(self) if block
  end

  def reducer(*initial, &block)
    @reducer = [initial, block]
    self
  end

  def limiter(&block)
    @limiter = block
    self
  end

  def rescuer(kind = StandardError, &block)
    @rescuers[kind] = block
    self
  end

  def debounce(id = nil, *args, &block)
    raise ArgumentError, 'Expected a block' unless block
    exclusively do
      thread = @timeouts[id] ||= new_thread { begin_delay id, &block }
      @flush = [id]
      args   = reduce_args(thread, args, id)
      if (@limiter && !@limiter[*args]) || @flush == true
        thread.kill
        @timeouts.delete id
        @threads.delete thread
        @flush = false
      else
        thread[:args]   = args
        thread[:run_at] = Time.now + @delay
      end
    end or
        yield *args
    self
  end

  def flush(*args)
    if args.empty?
      if @lock.owned?
        @flush = true
      else
        flush @timeouts.keys.first while @timeouts.any?
      end
    else
      id = args.first
      if @lock.owned? && @flush == [id]
        @flush = true
      else
        dead = exclusively do
          if (thread = @timeouts.delete(id))
            thread.kill
            @threads.delete thread
          end
        end
        dead[:block].call *dead[:args] if dead
      end
    end
    self
  end

  def join(kill_first = false)
    while (thread = exclusively { @threads.find &:alive? })
      thread.kill if kill_first
      thread.join
    end
    exclusively { [@threads, @timeouts].each &:clear } if kill_first
    self
  end

  def kill
    join true
  end

  def inspect
    "#<#{self.class}:0x#{'%014x' % (object_id << 1)} delay: #{@delay} timeouts: #{@timeouts.count} threads: #{@threads.count}>"
  end

  private

  def begin_delay(id, &block)
    thread[:block] = block
    sleep @delay
    until exclusively { (thread[:run_at] <= Time.now).tap { |ready| @timeouts.delete id if ready } }
      sleep [thread[:run_at] - Time.now, 0].max
    end
    yield *thread[:args]
  rescue => ex
    @timeouts.reject! { |_, v| v == thread }
    (rescuer = @rescuers.find { |klass, _| ex.is_a? klass }) && rescuer.last[ex]
  ensure
    exclusively { @threads.delete thread }
  end

  def reduce_args(thread, new_args, id)
    old_args = thread[:args]
    if @reducer
      initial, reducer = @reducer
      reducer[old_args || initial || [], new_args, id]
    else
      new_args.empty? ? old_args : new_args
    end
  end

  def new_thread(*args, &block)
    Thread.new(*args, &block).tap { |t| @threads << t }
  end

  def exclusively(&block)
    @lock.synchronize &block
  end

  def thread
    Thread.current
  end
end
