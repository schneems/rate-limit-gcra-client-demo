require 'monitor'
require 'excon'

CLIENT_COUNT = ENV.fetch("CLIENT_COUNT") { 5 }.to_i
PROCESS_COUNT = ENV.fetch("PROCESS_COUNT") { 2 }.to_i

module RateLimit
  MAX_LIMIT = 4500.to_f
  MIN_SLEEP = 1/(MAX_LIMIT / 3600)
  @monitor = Monitor.new # Reentrant mutex
  @sleep_for = 0.0
  @rate_limit_count = 0

  def self.call(&block)
    rate_limit_count = @rate_limit_count

    jitter = @sleep_for * rand(0.0..0.1)
    sleep(@sleep_for + jitter)

    req = yield

    remaining = req.headers["RateLimit-Remaining"].to_i

    status_string = String.new("")
    status_string << "#{Process.pid}##{Thread.current.object_id}: "
    status_string << "#status=#{req.status} "
    status_string << "#remaining=#{remaining} "
    status_string << "#sleep_for=#{@sleep_for} "
    puts status_string

    @monitor.synchronize do
      if req.status == 429
        # This was tough to figure out
        #
        # Basically when we hit a rate limiting event, we don't want all
        # threads to be increasing the guess size, really just the first client
        # to do the job of figuring how much it should slow down. The other jobs
        # should sit and wait for a number they can try.
        #
        # If this value is different than the value recorded at the beginning of the
        # request then it means another thread has already increased the client guess
        # and we should try using that value first before we try bumping it.
        if rate_limit_count == @rate_limit_count
          @sleep_for += MIN_SLEEP if @sleep_for <= 0
          @sleep_for *= 2
          @rate_limit_count += 1
        end

        # Retry the request with the new sleep value
        req = self.call(&block)
      else
        # The fewer available requests, the slower we should reduce our client guess.
        # We want this to converge and linger around a correct value rather than
        # being a true sawtooth pattern.
        @sleep_for -= remaining/MAX_LIMIT * MIN_SLEEP
        @sleep_for = 0 if @sleep_for <= 0
      end
    end

    return req
  end
end


def run
  loop do
    RateLimit.call do
      Excon.get("http://localhost:9292")
    end
  end
end

def spawn_threads
  threads = []
  CLIENT_COUNT.times.each do
    threads << Thread.new do
      run
    end
  end
  threads.map(&:join)
end

def spawn_processes
  PROCESS_COUNT.times.each do
    fork do
      spawn_threads
    end
  end

  Process.waitall
end

spawn_processes

