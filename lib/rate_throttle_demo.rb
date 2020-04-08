require 'excon'
require 'pathname'
require 'fileutils'
require 'date'
require 'json'
require 'timecop'
require 'wait_for_it'

Thread.abort_on_exception = true

# A class for simulating or "demoing" a rate throttle client
#
# Example:
#
#   duration = 3600 # seconds in one hour
#   client = ExponentialIncreaseSleepAndRemainingDecrease.new
#   demo = RateThrottleDemo.new(client: client, stream_requests: true, duration: duration)
#   demo.call
#   demo.print_results
#     # => max_sleep_val: [59.05, 80.58, 80.58, 80.58, 56.18, 56.18, 56.18, 59.05, 70.05, 70.05, 70.05, 59.15, 59.15, 59.15, 59.15, 70.05, 70.05, 59.15, 56.18, 80.58, 80.58, 59.05, 59.05, 59.05, 56.18]
#     # => retry_ratio: [0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.02, 0.01, 0.01, 0.01, 0.00, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01]
#     # => request_count: [3321.00, 1551.00, 2167.00, 2197.00, 1628.00, 1709.00, 1484.00, 3512.00, 1722.00, 2816.00, 3182.00, 2137.00, 4398.00, 2154.00, 2418.00, 2868.00, 2492.00, 2982.00, 1731.00, 2278.00, 1988.00, 4221.00, 3160.00, 2927.00, 2635.00]
#
# Arguments:
#
# Thread count can be controlled via the `thread_count` arguement, or the THREAD_COUNT env var (default is below).
# Process count can be controlled via the `process_count` arguement, or the PROCESS_COUNT env var (default is below).
# total number of clients is thread_count * process_count.
#
# Time scale can be controlled via the `time_scale` arguement, or the TIME_SCALE env var (default is below).
# The time scale value will speed up the simulation, for example `TIME_SCALE=10` means a 60 second simulation
# will complete in 6 minutes.
#
# The simulation will stop after `duration:` seconds.
# Outputting request logs to stdout can be enabled/disabled by setting `stream_requests`.
# The other way to stop a simulation is to specify `remaining_stop_under` when this value is set, the simulation
# will stop when the "remaining" limit count from the server is under this value.
#
# The starting "remaining" limit count in the server can be set via passing in the `starting_limit`, default is 0
# requests.
#
# Outputs:
#
# - Writes log outputs to stdout if `stream_requests` is true
# - Writes aggregate metrics of each client to an intermediate json file every @json_duration seconds. This is then later used to
#   produce the data for `print_results`
# - Writes the last value the client slept for to a newline separated file every 1 (real time, not simulated) second. This is used to
#   generate the charts using the `chart.rb` script.
class RateThrottleDemo
  MINUTE = 60
  THREAD_COUNT = ENV.fetch("THREAD_COUNT") { 5 }.to_i
  PROCESS_COUNT = ENV.fetch("PROCESS_COUNT") { 2 }.to_i
  DURATION=ENV.fetch("DURATION") { 30 }.to_i * MINUTE #
  TIME_SCALE = ENV.fetch("TIME_SCALE", 1).to_f
  RACKUP_FILE = Pathname.new(__dir__).join("../server/config.ru")

  def initialize(client:,thread_count: THREAD_COUNT, process_count: PROCESS_COUNT, duration: DURATION, log_dir: nil, time_scale: TIME_SCALE, stream_requests: false, json_duration: 30, rackup_file: RACKUP_FILE, starting_limit: 0, remaining_stop_under: nil)
    @client = client
    @thread_count = thread_count
    @process_count = process_count
    @duration = duration
    @log_dir = log_dir || Pathname.new(__dir__).join("../logs/clients/#{Time.now.strftime('%Y-%m-%d-%H-%M-%s-%N')}-#{client.class}")
    @time_scale = time_scale
    @stream_requests = stream_requests
    @rackup_file = rackup_file
    @starting_limit = starting_limit
    @remaining_stop_under = remaining_stop_under
    @json_duration = 30 # seconds
    @port = UniquePort.call
    @threads = []
    @pids = []
    Timecop.scale(@time_scale)

    FileUtils.mkdir_p(@log_dir)
  end

  def print_results
    puts
    puts "## Raw #{@client.class} results"
    puts
    self.results.each do |key, value|
      puts "#{key}: [#{ value.map {|x| "%.2f" % x}.join(", ")}]"
    end
  end

  def results
    result_hash = {}

    @log_dir.entries.map do |entry|
      @log_dir.join(entry)
    end.select do |file|
      file.file? && file.extname == ".json"
    end.map do |file|
      JSON.parse(file.read)
    end.each do |json|
      json.each_key do |key|
        result_hash[key] ||= []
        result_hash[key] << json[key]
      end
    end

    result_hash
  end

  def call
    WaitForIt.new("bundle exec puma #{@rackup_file.to_s} -p #{@port}", env: {"TIME_SCALE" => @time_scale.to_i.to_s, "STARTING_LIMIT" => @starting_limit.to_s}, wait_for: "Use Ctrl-C to stop") do |spawn|
      @process_count.times.each do
        @pids << fork do
          run_threads
        end
      end

      @pids.map { |pid| Process.wait(pid) }
    end
  end

  private def run_threads
    @thread_count.times.each do
      @threads << Thread.new do
        run_client_single
      end
    end

    # Chart support, print out the sleep value in 1 second increments to a file
    Thread.new do
      loop do
        @threads.each do |thread|
          sleep_for = thread.thread_variable_get("last_sleep_value") || 0

          File.open(@log_dir.join("#{Process.pid}:#{thread.object_id}-chart-data.txt"), 'a') do |f|
            f.puts(sleep_for)
          end
        end
        sleep 1 # time gets adjusted via TIME_SCALE later in time.rb
      end
    end

    @threads.map(&:join)
  end

  class TimeIsUpError < StandardError; end

  private def run_client_single
    end_at_time = Time.now + @duration
    next_json_time = Time.now + @json_duration
    request_count = 0
    retry_count = 0

    if !@client.instance_variable_get(:"@time_scale")
      def @client.sleep(val)
        @max_sleep_val = val if val > @max_sleep_val
        Thread.current.thread_variable_set("last_sleep_value", val)

        super val/@time_scale
      end

      def @client.max_sleep_val
        @max_sleep_val
      end

      def @client.last_sleep
        @last_sleep || 0
      end
    end

    @client.instance_variable_set(:"@time_scale", @time_scale)
    @client.instance_variable_set(:"@max_sleep_val", 0)

    loop do
      begin_time = Time.now
      break if begin_time > end_at_time
      if begin_time > next_json_time
        write_json_value(retry_count: retry_count, request_count: request_count, max_sleep_val: @client.max_sleep_val)
        next_json_time = begin_time + @json_duration
      end

      request = nil
      @client.call do
        request_count += 1

        request = begin
          Excon.get("http://localhost:#{@port}")
        rescue Excon::Error::Timeout => e
          puts e.inspect
          puts "retrying"
          retry
        end

        case request.status
        when 200
        when 429
          retry_count += 1
        else
          raise "Got unexpected reponse #{request.status}. #{request.inspect}"
        end

        if @stream_requests
          status_string = String.new
          status_string << "#{Process.pid}##{Thread.current.object_id}: "
          status_string << "status=#{request.status} "
          status_string << "remaining=#{request.headers["RateLimit-Remaining"]} "
          status_string << "retry_count=#{retry_count} "
          status_string << "request_count=#{request_count} "
          status_string << "max_sleep_val=#{ sprintf("%.2f", @client.max_sleep_val) } "

          puts status_string
        end

        request
      end

      break if @remaining_stop_under && (request.headers["RateLimit-Remaining"].to_i <= @remaining_stop_under)
    end

    @threads.each {|t|
      if t != Thread.current && t.backtrace_locations && t.backtrace_locations.first.label == "sleep"
        t.raise(TimeIsUpError)
      end
    }
  rescue Excon::Error::Socket => e
    raise e
  rescue TimeIsUpError
    # Since the sleep time can be very high, we need a way to notify sleeping threads they can stop
    # When this exception is raised, do nothing and exit
  ensure
    write_json_value(retry_count: retry_count, request_count: request_count, max_sleep_val: @client.max_sleep_val)
  end

  private def write_json_value(retry_count:, request_count:, max_sleep_val:)
    results = {
      max_sleep_val: max_sleep_val,
      retry_ratio: retry_count / request_count.to_f,
      request_count: request_count
    }

    File.open(@log_dir.join("#{Process.pid}:#{Thread.current.object_id}.json"), 'w+') do |f|
      f.puts(results.to_json)
    end
  rescue TimeIsUpError
    retry
  end
end

require 'socket'

module UniquePort
  def self.call
    TCPServer.open('127.0.0.1', 0) do |server|
      server.connect_address.ip_port
    end
  end
end

