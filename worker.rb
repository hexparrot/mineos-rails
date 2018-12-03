require 'json'
require 'eventmachine'
require 'securerandom'
require_relative 'mineos'

require 'logger'
logger = Logger.new(STDOUT)
logger.datetime_format = '%Y-%m-%d %H:%M:%S'
logger.level = Logger::DEBUG

require 'optparse'
options = {}
OptionParser.new do |opt|
  opt.on('--basedir PATH') { |o| options[:basedir] = o }
  opt.on('--workername NAME') { |o| options[:workername] = o }
end.parse!

if options[:basedir] then
  BASEDIR = Pathname.new(options[:basedir]).cleanpath
else
  BASEDIR = '/var/games/minecraft'
end

EM.run do
  servers = {}
  server_loggers = {}
  hostname = Socket.gethostname
  workername = options[:workername] || ENV['USER']
  logger.info("Starting up worker node: `#{workername}`")

  logger.info("Scanning servers from BASEDIR: #{BASEDIR}")
  server_dirs = Enumerator.new do |enum|
    Dir["#{BASEDIR}/servers/*"].each { |d|
      server_name = d[0..-1].match(/.*\/(.*)/)[1]
      enum.yield server_name
    }
  end

  server_dirs.each do |sn|
    #register existing servers upon startup
    servers[sn] = Server.new(sn, basedir:BASEDIR)
    logger.info("Finished setting up server instance: `#{sn}`")
  end

  require 'yaml'
  mineos_config = YAML::load_file('config/secrets.yml')
  logger.info("Finished loading mineos secrets.")

  require 'bunny'
  conn = Bunny.new(:host => mineos_config['rabbitmq']['host'],
                   :port => mineos_config['rabbitmq']['port'],
                   :user => mineos_config['rabbitmq']['user'],
                   :pass => mineos_config['rabbitmq']['pass'],
                   :vhost => mineos_config['rabbitmq']['vhost'])
  conn.start
  logger.info("Finished creating AMQP connection.")

  ch = conn.create_channel
  exchange = ch.topic("backend")
  exchange_stdout = ch.direct("stdout")

  directive_handler = lambda { |delivery_info, metadata, payload|
    case payload
    when "IDENT"
      exchange.publish({host: hostname,
                        workername: workername}.to_json,
                       :routing_key => "to_hq",
                       :timestamp => Time.now.to_i,
                       :type => 'receipt.directive',
                       :correlation_id => metadata[:message_id],
                       :headers => {hostname: hostname,
                                    workername: workername,
                                    directive: 'IDENT'},
                       :message_id => SecureRandom.uuid)
      logger.info("Received IDENT directive from HQ.")
    when "LIST"
      exchange.publish({servers: server_dirs.to_a}.to_json,
                       :routing_key => "to_hq",
                       :timestamp => Time.now.to_i,
                       :type => 'receipt.directive',
                       :correlation_id => metadata[:message_id],
                       :headers => {hostname: hostname,
                                    workername: workername,
                                    directive: 'LIST'},
                       :message_id => SecureRandom.uuid)
      logger.info("Received LIST directive from HQ.")
      logger.debug({servers: server_dirs.to_a})
    when "USAGE"
      require 'usagewatch'

      EM.defer do
        usw = Usagewatch
        retval = {
          uw_cpuused: usw.uw_cpuused,
          uw_memused: usw.uw_memused,
          uw_load: usw.uw_load,
          uw_diskused: usw.uw_diskused,
          uw_diskused_perc: usw.uw_diskused_perc,
        }
        exchange.publish({usage: retval}.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.directive',
                         :correlation_id => metadata[:message_id],
                         :headers => {hostname: hostname,
                                      workername: workername,
                                      directive: 'USAGE'},
                         :message_id => SecureRandom.uuid)
        logger.info("Received USAGE directive from HQ.")
        logger.debug({usage: retval})
      end
    when /(uw_\w+)/
      require 'usagewatch'

      EM.defer do
        usw = Usagewatch
        exchange.publish({usage: {$1 =>  usw.public_send($1)}}.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.directive',
                         :correlation_id => metadata[:message_id],
                         :headers => {hostname: hostname,
                                      workername: workername,
                                      directive: 'REQUEST_USAGE'},
                         :message_id => SecureRandom.uuid)
        logger.info("Received USAGE directive from HQ.")
        logger.debug({usage: {$1 =>  usw.public_send($1)}})
      end
    else
      json_in = JSON.parse payload
      if json_in.key?('AWSCREDS') then
        parsed = json_in['AWSCREDS']
  
        require 'aws-sdk-s3'
        Aws.config.update({
          endpoint: parsed['endpoint'],
          access_key_id: parsed['access_key_id'],
          secret_access_key: parsed['secret_access_key'],
          force_path_style: true,
          region: parsed['region']
        })
  
        logger.info("Received AWSCREDS directive from HQ.")

        begin
          c = Aws::S3::Client.new
        rescue ArgumentError => e
          retval = {
            endpoint: nil,
            access_key_id: nil,
            secret_access_key: nil,
            force_path_style: true,
            region: nil
          } 
          logger.error("Endpoint invalid and Aws::S3::Client.new failed. Returning:")
          logger.debug(retval)
        else
          retval = Aws.config
          logger.info("Endpoint valid and Aws::S3::Client.new returned no error")
          logger.debug(retval)
        end
  
        exchange.publish(retval.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.directive',
                         :correlation_id => metadata[:message_id],
                         :headers => {hostname: hostname,
                                      workername: workername,
                                      directive: 'AWSCREDS'},
                         :message_id => SecureRandom.uuid)
      else #if unknown directive
        exchange.publish({}.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.directive',
                         :correlation_id => metadata[:message_id],
                         :headers => {hostname: hostname,
                                      workername: workername,
                                      directive: 'BOGUS'}, #changing directive
                         :message_id => SecureRandom.uuid)
        logger.warn("Received bogus directive from HQ. Received:")
        logger.warn(payload)
        logger.warn("Ignored as BOGUS. Returned: {}")

      end # json_in.key
    end
  }

  command_handler = lambda { |delivery_info, metadata, payload|
    parsed = JSON.parse payload
    server_name = parsed.delete("server_name")
    cmd = parsed.delete("cmd")

    logger.info("Received #{cmd} for server `#{server_name}")
    logger.info(parsed)

    if servers[server_name].is_a? Server then
      inst = servers[server_name]
    else
      inst = Server.new(server_name, basedir:BASEDIR)
      servers[server_name] = inst
    end

    if !server_loggers[server_name] then
      server_loggers[server_name] = Thread.new do
        loop do
          line = inst.console_log.shift.strip
          puts line
          exchange_stdout.publish({ msg: line,
                                    server_name: server_name }.to_json,
                                  :routing_key => "to_hq",
                                  :timestamp => Time.now.to_i,
                                  :type => 'stdout',
                                  :correlation_id => metadata[:message_id],
                                  :headers => {hostname: hostname},
                                  :message_id => SecureRandom.uuid)
        end # loop
      end # Thread.new
    end

    return_object = {server_name: server_name, cmd: cmd, success: false, retval: nil}

    if inst.respond_to?(cmd) then
      reordered = []
      inst.method(cmd).parameters.map do |req_or_opt, name|
        begin
          if parsed[name.to_s][0] == ':' then
            #if string begins with :, interpret as symbol (remove : and convert)
            reordered << parsed[name.to_s][1..-1].to_sym
          else
            reordered << parsed[name.to_s]
          end
        rescue NoMethodError => e
          #logger.debug(e)
          #occurs if optional arguments are not provided (non-fatal)
          #invalid arguments will break at inst.public_send below
          #break out if first argument opt or not is absent
          break
        end
      end #map

      to_call = Proc.new do
        begin
          retval = inst.public_send(cmd, *reordered)
          if cmd == 'delete' then
            servers.delete(server_name)
            server_loggers.delete(server_name)
          end
          return_object[:retval] = retval
        rescue IOError => e
          logger.error("IOError caught!")
          logger.error("Worker process may no longer be attached to child process?")
          exchange.publish(return_object.to_json,
                           :routing_key => "to_hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.command',
                           :correlation_id => metadata[:message_id],
                           :headers => {hostname: hostname,
                                        workername: workername,
                                        exception: {name: 'IOError',
                                                    detail: e.to_s }},
                           :message_id => SecureRandom.uuid)
        rescue ArgumentError => e
          logger.error("ArgumentError caught!")
          exchange.publish(return_object.to_json,
                           :routing_key => "to_hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.command',
                           :correlation_id => metadata[:message_id],
                           :headers => {hostname: hostname,
                                        workername: workername,
                                        exception: {name: 'ArgumentError',
                                                    detail: e.to_s }},
                           :message_id => SecureRandom.uuid)
        rescue RuntimeError => e
          logger.error("RuntimeError caught!")
          logger.debug(e)
          logger.debug(return_object)
          exchange.publish(return_object.to_json,
                           :routing_key => "to_hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.command',
                           :correlation_id => metadata[:message_id],
                           :headers => {hostname: hostname,
                                        workername: workername,
                                        exception: {name: 'ArgumentError',
                                                    detail: e.to_s }},
                           :message_id => SecureRandom.uuid)
        else
          return_object[:success] = true
          logger.debug(return_object)
          exchange.publish(return_object.to_json,
                           :routing_key => "to_hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.command',
                           :correlation_id => metadata[:message_id],
                           :headers => {hostname: hostname,
                                        workername: workername,
                                        exception: false},
                           :message_id => SecureRandom.uuid)
        end
      end #to_call

      EM.defer to_call
    else #method not defined in api
      cb = Proc.new { |retval|
        exchange.publish(return_object.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.command',
                         :correlation_id => metadata[:message_id],
                         :headers => {hostname: hostname,
                                      workername: workername,
                                      exception: {name: 'NameError',
                                                  detail: "undefined method `#{cmd}' for class `Server'" }},
                         :message_id => SecureRandom.uuid)
      }
      EM.defer cb
    end #inst.respond_to

  }

  ch
  .queue('directive')
  .bind(exchange, :routing_key => 'to_workers')
  .subscribe do |delivery_info, metadata, payload|
    if delivery_info.routing_key == 'to_workers' then
      directive_handler.call delivery_info, metadata, payload
    else
      #logger.debug(delivery_info)
      #logger.debug(metadata)
      #logger.debug(payload)
    end
  end

  ch
  .queue('command')
  .bind(exchange, :routing_key => "to_workers.#{hostname}.#{workername}")
  .subscribe do |delivery_info, metadata, payload|
    dest = delivery_info.routing_key.split('.')
    if dest[1] == hostname and dest[2] == workername then
      command_handler.call delivery_info, metadata, payload
    else
      #logger.debug(delivery_info)
      #logger.debug(metadata)
      #logger.debug(payload)
    end
  end

  exchange.publish({host: hostname,
                    workername: workername}.to_json,
                    :routing_key => "to_hq",
                    :timestamp => Time.now.to_i,
                    :type => 'receipt.directive',
                    :correlation_id => nil,
                    :headers => {hostname: hostname,
                                 workername: workername,
                                 directive: 'IDENT'},
                    :message_id => SecureRandom.uuid)
  logger.info("Sent IDENT message.")
  logger.info("Worker node set up and listening.")

end #EM::Run
