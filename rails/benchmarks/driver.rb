#
# Rails Benchmark driver
#
require 'bundler/setup'
require 'net/http'
require 'json'
require 'pathname'
require 'optparse'
require 'rails'
require 'digest'

RAW_URL = 'https://raw.githubusercontent.com/ruby-bench/ruby-bench-suite/master/rails/benchmarks/'

DATABASE_URLS = {
  psql: "postgres://postgres@postgres:5432/rubybench",
  mysql: "mysql2://root@mysql:3306/rubybench",
}

class BenchmarkDriver
  def self.benchmark(options)
    self.new(options).run
  end

  def initialize(options)
    @repeat_count = options[:repeat_count]
    @pattern = options[:pattern]
  end

  def run
    files.each do |path|
      next if !@pattern.empty? && /#{@pattern.join('|')}/ !~ File.basename(path)

      if path.match(/activerecord|scaffold/)
        DATABASE_URLS.each do |database, url|
          run_single(path, connection: url, database: database)
        end
      else
        run_single(path)
      end
    end
  end

  private

  def measure_active_record(script, connection, path, database)
    connection_string = Proc.new do |prepared_statements|
      "DATABASE_URL=#{connection}?prepared_statements=#{prepared_statements} #{script}"
    end

    with_prepared_statements = measure(connection_string.call(true))
    return unless with_prepared_statements
    without_prepared_statements = measure(connection_string.call(false))
    return unless without_prepared_statements

    form_data = default_form_data(with_prepared_statements, path, database)

    submit_request(form_data, {
      "benchmark_run[result][with_prepared_statements]" => with_prepared_statements["iterations_per_second"].round(3),
      "benchmark_run[result][without_prepared_statements]" => without_prepared_statements["iterations_per_second"].round(3),
      'benchmark_result_type[name]' => 'Number of iterations per second',
      'benchmark_result_type[unit]' => 'Iterations per second'
    })

    submit_request(form_data, {
      "benchmark_run[result][with_prepared_statements]" => with_prepared_statements["total_allocated_objects_per_iteration"],
      "benchmark_run[result][without_prepared_statements]" => without_prepared_statements["total_allocated_objects_per_iteration"],
      'benchmark_result_type[name]' => 'Allocated objects',
      'benchmark_result_type[unit]' => 'Objects'
    })
  end

  def generate_request
    request = Net::HTTP::Post.new('/benchmark_runs')
    request.basic_auth(ENV["API_NAME"], ENV["API_PASSWORD"])
    request
  end

  def default_form_data(output, path, database)
    data = {
      'benchmark_type[category]' => output["label"],
      'benchmark_type[script_url]' => "#{RAW_URL}#{Pathname.new(path).basename}",
      'benchmark_type[digest]' => generate_digest(path, database),
      'benchmark_run[environment]' => "#{`ruby -v`}",
      'repo' => 'rails',
      'organization' => 'rails'
    }

    if(ENV['RAILS_COMMIT_HASH'])
      data['commit_hash'] = ENV['RAILS_COMMIT_HASH']
    elsif(ENV['RAILS_VERSION'])
      data['version'] = ENV['RAILS_VERSION']
    end

    data
  end

  def submit_request(form_data, results)
    request = generate_request
    request.set_form_data(form_data.merge(results))
    endpoint.request(request)
  end

  def files
    Dir["#{File.expand_path(File.dirname(__FILE__))}/*"].select! { |path| path =~ /bm_.+/ }
  end

  def run_single(path, connection: nil, database: nil)
    script = "RAILS_ENV=production ruby #{path}"

    if connection
      measure_active_record(script, connection, path, database)
    else
      output = measure(script)
      return unless output
      form_data = default_form_data(output, path, database)

      submit_request(form_data, {
        "benchmark_run[result][iterations_per_second]" => output["iterations_per_second"].round(3),
        'benchmark_result_type[name]' => 'Number of iterations per second',
        'benchmark_result_type[unit]' => 'Iterations per second'
      })

      submit_request(form_data, {
        "benchmark_run[result][total_allocated_objects_per_iteration]" => output["total_allocated_objects_per_iteration"],
        'benchmark_result_type[name]' => 'Allocated objects',
        'benchmark_result_type[unit]' => 'Objects'
      })
    end

    puts "Posting results to Web UI...."
  end

  def endpoint
    http = Net::HTTP.new(ENV["API_URL"] || 'rubybench.org', 443)
    http.use_ssl = true
    http
  end

  def generate_digest(path, database)
    string = "#{File.read(path)}#{`ruby -v`}"

    case database
    when 'psql'
      string = "#{string}#{ENV['POSTGRES_ENV_PG_VERSION']}"
    when 'mysql'
      string = "#{string}#{ENV['MYSQL_ENV_MYSQL_VERSION']}"
    end

    Digest::SHA2.hexdigest(string)
  end

  def measure(script)
    begin
      results = []

      @repeat_count.times do
        result = JSON.parse(`#{script}`)
        puts "#{result["label"]} #{result["iterations_per_second"]}/ips #{result["total_allocated_objects_per_iteration"]} objects allocated"
        results << result
      end

      results.sort_by do |result|
        result['iterations_per_second']
      end.last
    rescue JSON::ParserError
      # Do nothing
    end
  end
end

options = {
  repeat_count: 1,
  pattern: []
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby driver.rb [options]"

  opts.on("-r", "--repeat-count [NUM]", "Run benchmarks [NUM] times taking the best result") do |value|
    options[:repeat_count] = value.to_i
  end

  opts.on("-p", "--pattern <PATTERN1,PATTERN2,PATTERN3>", "Benchmark name pattern") do |value|
    options[:pattern] = value.split(',')
  end
end.parse!(ARGV)

BenchmarkDriver.benchmark(options)
