require 'json'
require 'eventmachine'
require 'securerandom'

EM.run do
  hostname = Socket.gethostname

  require 'yaml'
  amqp_creds = YAML::load_file('config/amqp.yml')['rabbitmq'].transform_keys(&:to_sym)

  require 'bunny'
  conn = Bunny.new(amqp_creds)
  conn.start

  ch = conn.create_channel
  exchange = ch.topic("backend")

  directive_handler = lambda { |delivery_info, metadata, payload|
    case payload
    when 'IDENT'
      EM::Timer.new(1) do
        exchange.publish({ host: hostname }.to_json,
                             :routing_key => "hq",
                             :timestamp => Time.now.to_i,
                             :type => 'receipt',
                             :correlation_id => metadata[:message_id],
                             :headers => { hostname: hostname,
                                           directive: 'IDENT' },
                             :message_id => SecureRandom.uuid)
      end
    else
      json_in = JSON.parse payload

      if json_in.key?('MKPOOL') then
        require_relative 'pools'

        worker = json_in['MKPOOL']['workerpool']
        pool_inst = Pools.new
        pool_inst.create_pool(worker, 'mypassword')
        puts "Created pool: #{worker}"
      elsif json_in.key?('SPAWN') then
        def as_user(user, script_path, &block)
          require 'etc'
          # Find the user in the password database.
          u = (user.is_a? Integer) ? Etc.getpwuid(user) : Etc.getpwnam(user)

          # Fork the child process. Process.fork will run a given block of code
          # in the child process.
          p1 = Process.fork do
            Process.setsid
            p2 = Process.fork do
              # We're in the child. Set the process's user ID.
              Process.gid = Process.egid = u.uid
              Process.uid = Process.euid = u.uid

              # Invoke the caller's block of code.
              Dir.chdir(script_path) do
                block.call
              end
            end #p2
            Process.detach(p2)
          end #p1
          Process.detach(p1)
        end

        worker = json_in['SPAWN']['workerpool']
        rb_script_path = File.expand_path(File.dirname(__FILE__))
        pickled_creds = YAML::dump(amqp_creds)

        as_user(worker, rb_script_path) do
          # works but has unfortunate side-effect of echoing creds to
          # stdout from root's terminal when killed
          #exec "ruby worker.rb --basedir /home/#{user}/minecraft"
          exec "echo '#{pickled_creds}' | ruby worker.rb --amqp-stdin --basedir /home/#{worker}/minecraft"
        end

        exchange.publish({ host: hostname,
                           workerpool: worker }.to_json,
                         :routing_key => "hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt',
                         :correlation_id => metadata[:message_id],
                         :headers => { hostname: hostname,
                                       workerpool: worker, 
                                       directive: 'SPAWN' },
                         :message_id => SecureRandom.uuid)

      elsif json_in.key?('REMOVE') then
        require_relative 'pools'

        worker = json_in['REMOVE']['workerpool']
        pool_inst = Pools.new
        pool_inst.remove_pool(worker)
        puts "Removed pool: #{worker}"
      end #if
    end #case
  } #end directive_handler

  ch
  .queue("managers.#{hostname}")
  .bind(exchange, routing_key: "managers.#")
  .subscribe do |delivery_info, metadata, payload|
    if delivery_info[:routing_key] == "managers.#{hostname}" then
puts delivery_info
      directive_handler.call delivery_info, metadata, payload
    end
  end

  exchange.publish({ host: hostname }.to_json,
                   :routing_key => "hq",
                   :timestamp => Time.now.to_i,
                   :type => 'directive',
                   :correlation_id => nil,
                   :headers => { hostname: hostname,
                                 directive: 'IDENT' },
                   :message_id => SecureRandom.uuid)

end #EM::Run

