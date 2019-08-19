require 'monitor'
require 'excon'

CLIENT_COUNT = ENV.fetch("CLIENT_COUNT") { 5 }.to_i
PROCESS_COUNT = ENV.fetch("PROCESS_COUNT") { 2 }.to_i

module RateLimit
  MAX_LIMIT = 4500.to_f
  @monitor = Monitor.new # Reentrant mutex
  @arrival_rate = MAX_LIMIT
  @client_guess = nil
  @rate_limit = 0

  def self.sleep_for_client_count
    return 0 if @client_guess.nil?
    return 0 if @client_guess < 0

    sleep_for = @client_guess * 1/(@arrival_rate / 3600)
    jitter = sleep_for * rand(0.0..0.1)
    return sleep_for + jitter
  end

  def self.call(&block)
    rate_limit_count = @rate_limit

    sleep_for = sleep_for_client_count
    sleep(sleep_for)

    req = yield

    remaining = req.headers["RateLimit-Remaining"].to_i

    status_string = String.new("")
    status_string << "#{Process.pid}##{Thread.current.object_id}: "
    status_string << "#status=#{req.status} "
    status_string << "#client_guess=#{@client_guess || 0} "
    status_string << "#remaining=#{remaining} "
    status_string << "#sleep_for=#{sleep_for} "
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
        if rate_limit_count == @rate_limit
          @client_guess ||= 2
          @client_guess *= 2
          @rate_limit += 1

          multiplier = req.headers["RateLimit-Multiplier"].to_f
          @arrival_rate = multiplier * MAX_LIMIT
        end

        # Retry the request with the new sleep value
        req = self.call(&block)
      else
        # The fewer available requests, the slower we should reduce our client guess.
        # We want this to converge and linger around a correct value rather than
        # being a true sawtooth pattern.
        @client_guess -= remaining / MAX_LIMIT if @client_guess
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
