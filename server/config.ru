require 'thread'

require 'pathname'
require 'fileutils'
require 'date'
LOG_DIR = Pathname.new(__FILE__).join("../../logs/server/#{Time.now.strftime('%Y-%m-%d-%H-%M-%s-%N')}")
FileUtils.mkdir_p(LOG_DIR)
LOG_FILE = LOG_DIR.join(Process.pid.to_s)
@rate_limit_count = 0

MAX_REQUESTS = 4500
limit_left = 500.to_f
last_request = Time.now
rate_of_limit_gain = MAX_REQUESTS / 3600.to_f
mutex = Mutex.new

if ENV["TIME_SCALE"]
  require 'timecop'
  Timecop.scale(ENV["TIME_SCALE"].to_f)
end

app = -> (env) do
  remaining = nil
  mutex.synchronize do
    limit_left -= 1 if limit_left > 0

    if limit_left < MAX_REQUESTS
      current_request = Time.now
      time_diff = current_request - last_request
      last_request = current_request
      limit_left = [limit_left + time_diff * rate_of_limit_gain, MAX_REQUESTS].min
    end

    remaining = [limit_left.floor, 0].max
    @rate_limit_count += 1 if remaining <= 0
    # File.open(LOG_FILE, 'a') { |f| f.puts("#{DateTime.now.iso8601},#{@rate_limit_count.to_s}") }
  end

  headers = { "RateLimit-Remaining" => remaining, "RateLimit-Multiplier" => 1, "Content-Type" => "text/plain".freeze }
  if remaining <= 0
    status = 429
    body = "!!!!! Nope !!!!!".freeze
  else
    status = 200
    body = "<3<3<3 Hello world <3<3<3".freeze
  end

  return [status, headers, [body]]
end

run app
