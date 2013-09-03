require 'thor'
require 'norikra/client'

require 'norikra/client/cli/parser'
require 'norikra/client/cli/formatter'

class Norikra::Client
  module CLIUtil
    def client(options)
      Norikra::Client.new(options[:host], options[:port])
    end
    def wrap
      begin
        yield
      rescue Norikra::RPC::ClientError => e
        puts "Failed: " + e.message
      rescue Norikra::RPC::ServerError => e
        puts "ERROR on norikra server: " + e.message
        puts " For more details, see norikra server's logs"
      end
    end
  end

  class Target < Thor
    include Norikra::Client::CLIUtil

    desc "list", "show list of targets"
    option :simple, :type => :boolean, :default => false, :desc => "suppress header/footer", :aliases => "-s"
    def list
      wrap do
        puts "TARGET" unless options[:simple]
        targets = client(parent_options).targets
        targets.each do |t|
          puts t
        end
        puts "#{targets.size} targets found." unless options[:simple]
      end
    end

    desc "open TARGET [fieldname1:type1 [fieldname2:type2 [fieldname3:type3] ...]]", "create new target (and define its fields)"
    def open(target, *field_defs)
      wrap do
        fields = nil
        if field_defs.size > 0
          fields = {}
          field_defs.each do |str|
            fname,ftype = str.split(':')
            fields[fname] = ftype
          end
        end
        client(parent_options).open(target, fields)
      end
    end

    desc "close TARGET", "close existing target and all its queries"
    def close(target)
      wrap do
        client(parent_options).close(target)
      end
    end
  end

  class Query < Thor
    include Norikra::Client::CLIUtil

    desc "list", "show list of queries"
    option :simple, :type => :boolean, :default => false, :desc => "suppress header/footer", :aliases => "-s"
    def list
      wrap do
        puts ["QUERY_NAME", "GROUP", "TARGETS", "QUERY"].join("\t") unless options[:simple]
        queries = client(parent_options).queries
        queries.sort{|a,b| (a['targets'].first <=> b['targets'].first).nonzero? || a['name'] <=> b['name']}.each do |q|
          puts [
            q['name'],
            (q['group'] || 'default'),
            q['targets'].join(','),
            q['expression']
          ].join("\t")
        end
        puts "#{queries.size} queries found." unless options[:simple]
      end
    end

    desc "add QUERY_NAME QUERY_EXPRESSION", "register a query"
    option :group, :type => :string, :default => nil, :desc => "query group for sweep/listen (default: null)", :aliases => "-g"
    def add(query_name, expression)
      wrap do
        client(parent_options).register(query_name, options[:group], expression)
      end
    end

    desc "remove QUERY_NAME", "deregister a query"
    def remove(query_name)
      wrap do
        client(parent_options).deregister(query_name)
      end
    end
  end

  class Field < Thor
    include Norikra::Client::CLIUtil

    desc "list TARGET", "show list of field definitions of specified target"
    option :simple, :type => :boolean, :default => false, :desc => "suppress header/footer", :aliases => "-s"
    def list(target)
      wrap do
        puts "FIELD\tTYPE\tOPTIONAL" unless options[:simple]
        fields = client(parent_options).fields(target)
        fields.each do |f|
          puts "#{f['name']}\t#{f['type']}\t#{f['optional']}"
        end
        puts "#{fields.size} fields found." unless options[:simple]
      end
    end

    desc "add TARGET FIELDNAME TYPE", "reserve fieldname and its type of target"
    def add(target, field, type)
      wrap do
        client(parent_options).reserve(target, field, type)
      end
    end
  end

  class Event < Thor
    include Norikra::Client::CLIUtil

    desc "send TARGET", "send data into targets"
    option :format, :type => :string, :default => 'json', :desc => "format of input data per line of stdin [json(default), ltsv]"
    option :batch_size, :type => :numeric, :default => 10000, :desc => "records sent in once transferring (default: 10000)"
    def send(target)
      wrap do
        client = client(parent_options)
        parser = parser(options[:format])
        buffer = []
        $stdin.each_line do |line|
          buffer.push(parser.parse(line))
          if buffer.size >= options[:batch_size]
            client.send(target, buffer)
            buffer = []
          end
        end
        client.send(target, buffer) if buffer.size > 0
      end
    end

    desc "fetch QUERY_NAME", "fetch events from specified query"
    option :format, :type => :string, :default => 'json', :desc => "format of output data per line of stdout [json(default), ltsv]"
    option :time_key, :type => :string, :default => 'time', :desc => "output key name for event time (default: time)"
    option :time_format, :type => :string, :default => '%Y/%m/%d %H:%M:%S', :desc => "output time format (default: '2013/05/14 17:57:59')"
    def fetch(query_name)
      wrap do
        formatter = formatter(options[:format])
        time_formatter = lambda{|t| Time.at(t).strftime(options[:time_format])}

        client(parent_options).event(query_name).each do |time,event|
          event = {options[:time_key] => Time.at(time).strftime(options[:time_format])}.merge(event)
          puts formatter.format(event)
        end
      end
    end

    desc "sweep [query_group_name]", "fetch all output events of all queries of default (or specified) query group"
    option :format, :type => :string, :default => 'json', :desc => "format of output data per line of stdout [json(default), ltsv]"
    option :query_name_key, :type => :string, :default => 'query', :desc => "output key name for query name (default: query)"
    option :time_key, :type => :string, :default => 'time', :desc => "output key name for event time (default: time)"
    option :time_format, :type => :string, :default => '%Y/%m/%d %H:%M:%S', :desc => "output time format (default: '2013/05/14 17:57:59')"
    def sweep(query_group=nil)
      wrap do
        formatter = formatter(options[:format])
        time_formatter = lambda{|t| Time.at(t).strftime(options[:time_format])}

        data = client(parent_options).sweep(query_group)

        data.keys.sort.each do |queryname|
          events = data[queryname]
          events.each do |time,event|
            event = {
              options[:time_key] => Time.at(time).strftime(options[:time_format]),
              options[:query_name_key] => queryname,
            }.merge(event)
            puts formatter.format(event)
          end
        end
      end
    end
  end

  class CLI < Thor
    include Norikra::Client::CLIUtil

    class_option :host, :type => :string, :default => 'localhost'
    class_option :port, :type => :numeric, :default => 26571

    desc "target CMD ...ARGS", "manage targets"
    subcommand "target", Target

    desc "field CMD ...ARGS", "manage target field/datatype definitions"
    subcommand "field", Field

    desc "query CMD ...ARGS", "manage queries"
    subcommand "query", Query

    desc "event CMD ...ARGS", "send/fetch events"
    subcommand "event", Event
  end
end
