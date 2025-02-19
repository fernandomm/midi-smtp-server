# frozen_string_literal: true

require 'logger'
require 'socket'
require 'resolv'
require 'base64'

# A small and highly customizable ruby SMTP-Server.
module MidiSmtpServer

  # import sources
  require 'midi-smtp-server/version'
  require 'midi-smtp-server/exceptions'
  require 'midi-smtp-server/logger'
  require 'midi-smtp-server/tls-transport'

  # default values
  DEFAULT_SMTPD_HOST = '127.0.0.1'
  DEFAULT_SMTPD_PORT = 2525
  DEFAULT_SMTPD_PRE_FORK = 0
  DEFAULT_SMTPD_MAX_PROCESSINGS = 4

  # default values for conformity to RFC(2)822 and additional
  # if interested in details, checkout discussion on issue queue at:
  # https://github.com/4commerce-technologies-AG/midi-smtp-server/issues/16
  CRLF_MODES = [:CRLF_ENSURE, :CRLF_LEAVE, :CRLF_STRICT].freeze
  DEFAULT_CRLF_MODE = :CRLF_ENSURE

  # default values for IO operations
  DEFAULT_IO_CMD_TIMEOUT = 30
  DEFAULT_IO_BUFFER_CHUNK_SIZE = 4 * 1024
  DEFAULT_IO_BUFFER_MAX_SIZE = 1 * 1024 * 1024

  # default value for SMTPD extensions support
  DEFAULT_PIPELINING_EXTENSION_ENABLED = false
  DEFAULT_INTERNATIONALIZATION_EXTENSIONS_ENABLED = false

  # Authentication modes
  AUTH_MODES = [:AUTH_FORBIDDEN, :AUTH_OPTIONAL, :AUTH_REQUIRED].freeze
  DEFAULT_AUTH_MODE = :AUTH_FORBIDDEN

  # class for SmtpServer
  class Smtpd

    public

    # Create the server
    def start
      create_service
    end

    # Stop the server
    def stop(wait_seconds_before_close: 2, gracefully: true)
      begin
        # signal pre_forked workers to stop
        @workers.each { |worker_pid| Process.kill(:TERM, worker_pid) } if pre_fork? && master?
        # always signal shutdown
        shutdown if gracefully
        # wait if some connection(s) need(s) more time to handle shutdown
        sleep wait_seconds_before_close if connections?
        # drop tcp_servers while raising SmtpdStopServiceException
        @connections_mutex.synchronize do
          @tcp_server_threads.each do |tcp_server_thread|
            # use safe navigation (&.) to make sure that obj exists like ... if tcp_server_thread
            tcp_server_thread&.raise SmtpdStopServiceException
          end
        end

      ensure
        # check for removing TCPServers
        @tcp_servers.each { |tcp_server| remove_tcp_server(tcp_server) } if master?
      end

      # wait if some connection(s) still need(s) more time to come down
      sleep wait_seconds_before_close if connections? || !stopped?
    end

    # Returns true if the server has stopped.
    def stopped?
      master? ? @workers.empty? && @tcp_server_threads.empty? && @tcp_servers.empty? : @tcp_server_threads.empty?
    end

    # Schedule a shutdown for the server
    def shutdown
      @shutdown = true
    end

    # test for shutdown state
    def shutdown?
      @shutdown
    end

    # Return the current number of connected clients
    def connections
      @connections.size
    end

    # Return if has active connected clients
    def connections?
      @connections.any?
    end

    # Return the current number of processed clients
    def processings
      @processings.size
    end

    # Return if has active processed clients
    def processings?
      @processings.any?
    end

    # Return if in pre-fork mode
    def pre_fork?
      @pre_fork > 1
    end

    # Return if this is the master process
    def master?
      !@is_forked
    end

    # Return if this is a forked worker process
    def worker?
      @is_forked
    end

    # Return number of forked worker processes
    def workers
      @workers.size
    end

    # Return if has active forked worker processes
    def workers?
      @workers.any?
    end

    # Join with the server thread(s)
    # before joining the server threads, check and wait optionally a few seconds
    # to let the service(s) come up
    def join(sleep_seconds_before_join: 1)
      # check already existing TCPServers
      return if @tcp_servers.empty?
      # check number of processes to pre-fork

      if pre_fork?
        # create a number of pre-fork processes and attach and join threads within workers
        @pre_fork.times do
          # append worker pid to list of workers
          @workers << fork do
            # set state for a forked process
            @is_forked = true
            # just attach and join the threads to forked worker process
            attach_threads
            join_threads(sleep_seconds_before_join: sleep_seconds_before_join)
          end
        end
        # Blocking wait until each worker process has been finished
        @workers.each { |pid| Process.waitpid(pid) }

      else
        # just attach and join the threads to running single master process (default)
        attach_threads
        join_threads(sleep_seconds_before_join: sleep_seconds_before_join)
      end
    end

    # Array of ports on which to bind, set as string separated by commata like '2525, 3535' or '2525:3535, 2525'
    def ports
      # prevent original array from being changed
      @ports.dup
    end

    # Array of hosts / ip_addresses on which to bind, set as string separated by commata like 'name.domain.com, 127.0.0.1, ::1'
    def hosts
      # prevent original array from being changed
      @hosts.dup
    end

    # Array of ip_address:port which get bound and build up from given hosts and ports
    def addresses
      # prevent original array from being changed
      @addresses.dup
    end

    # Current TLS OpenSSL::SSL::SSLContext when initialized by :TLS_OPTIONAL, :TLS_REQUIRED
    def ssl_context
      @tls&.ssl_context
    end

    # Maximum number of simultaneous processed connections, this does not limit the TCP connections itself, as a FixNum
    attr_reader :max_processings
    # Maximum number of allowed connections, this does limit the TCP connections, as a FixNum
    attr_reader :max_connections
    # CRLF handling based on conformity to RFC(2)822
    attr_reader :crlf_mode
    # Maximum time in seconds to wait for a complete incoming data line, as a FixNum
    attr_reader :io_cmd_timeout
    # Bytes to read non-blocking from socket into buffer, as a FixNum
    attr_reader :io_buffer_chunk_size
    # Maximum bytes to read as buffer before expecting completed incoming data line, as a FixNum
    attr_reader :io_buffer_max_size
    # Flag if should do reverse DNS lookups on incoming connections
    attr_reader :do_dns_reverse_lookup
    # Authentication mode
    attr_reader :auth_mode
    # Encryption mode
    attr_reader :encrypt_mode
    # handle SMTP PIPELINING extension
    attr_reader :pipelining_extension
    # handle SMTP 8BITMIME and SMTPUTF8 extension
    attr_reader :internationalization_extensions

    # logging object, may be overridden by special loggers like YELL or others
    attr_reader :logger

    # Initialize SMTP Server class
    #
    # +ports+:: ports to listen on. Allows multiple ports like "2525, 3535" or "2525:3535, 2525". Default value = DEFAULT_SMTPD_PORT
    # +hosts+:: interface ip or hostname to listen on or "*" to listen on all interfaces, allows multiple hostnames and ip_addresses like "name.domain.com, 127.0.0.1, ::1". Default value = DEFAULT_SMTPD_HOST
    # +pre_fork+:: number of processes to pre-fork to enable load balancing over multiple cores. Default value = DEFAULT_SMTPD_PRE_FORK
    # +max_processings+:: maximum number of simultaneous processed connections, this does not limit the number of concurrent TCP connections. Default value = DEFAULT_SMTPD_MAX_PROCESSINGS
    # +max_connections+:: maximum number of connections, this does limit the number of concurrent TCP connections (not set or nil => unlimited)
    # +crlf_mode+:: CRLF handling support (:CRLF_ENSURE [default], :CRLF_LEAVE, :CRLF_STRICT)
    # +do_dns_reverse_lookup+:: flag if this smtp server should do reverse DNS lookups on incoming connections
    # +io_cmd_timeout+:: time in seconds to wait until complete line of data is expected (DEFAULT_IO_CMD_TIMEOUT, nil => disabled test)
    # +io_buffer_chunk_size+:: size of chunks (bytes) to read non-blocking from socket (DEFAULT_IO_BUFFER_CHUNK_SIZE)
    # +io_buffer_max_size+:: max size of buffer (max line length) until \lf ist expected (DEFAULT_IO_BUFFER_MAX_SIZE, nil => disabled test)
    # +pipelining_extension+:: set to true for support of SMTP PIPELINING extension (DEFAULT_PIPELINING_EXTENSION_ENABLED)
    # +internationalization_extensions+:: set to true for support of SMTP 8BITMIME and SMTPUTF8 extensions (DEFAULT_INTERNATIONALIZATION_EXTENSIONS_ENABLED)
    # +auth_mode+:: enable builtin authentication support (:AUTH_FORBIDDEN [default], :AUTH_OPTIONAL, :AUTH_REQUIRED)
    # +tls_mode+:: enable builtin TLS support (:TLS_FORBIDDEN [default], :TLS_OPTIONAL, :TLS_REQUIRED)
    # +tls_cert_path+:: path to tls certificate chain file
    # +tls_key_path+:: path to tls key file
    # +tls_ciphers+:: allowed ciphers for connection
    # +tls_methods+:: allowed methods for protocol
    # +tls_cert_cn+:: set subject (CN) for self signed certificate "cn.domain.com"
    # +tls_cert_san+:: set subject alternative (SAN) for self signed certificate, allows multiple names like "alt1.domain.com, alt2.domain.com"
    # +logger+:: own logger class, otherwise default logger is created (DEPRECATED: use on_logging_event for special needs on logging)
    # +logger_severity+:: set or override the logger level if given
    def initialize(
      ports: DEFAULT_SMTPD_PORT,
      hosts: DEFAULT_SMTPD_HOST,
      pre_fork: DEFAULT_SMTPD_PRE_FORK,
      max_processings: DEFAULT_SMTPD_MAX_PROCESSINGS,
      max_connections: nil,
      crlf_mode: nil,
      do_dns_reverse_lookup: nil,
      io_cmd_timeout: nil,
      io_buffer_chunk_size: nil,
      io_buffer_max_size: nil,
      pipelining_extension: nil,
      internationalization_extensions: nil,
      auth_mode: nil,
      tls_mode: nil,
      tls_cert_path: nil,
      tls_key_path: nil,
      tls_ciphers: nil,
      tls_methods: nil,
      tls_cert_cn: nil,
      tls_cert_san: nil,
      logger: nil,
      logger_severity: nil
    )
      # create an exposed logger to forward logging to the on_logging_event
      @logger = MidiSmtpServer::ForwardingLogger.new(method(:on_logging_event))

      # external logging
      if logger.nil?
        @logger_protected = Logger.new($stdout)
        @logger_protected.datetime_format = '%Y-%m-%d %H:%M:%S'
        @logger_protected.formatter = proc { |severity, datetime, _progname, msg| "#{datetime}: [#{severity}] #{msg.chomp}\n" }
        @logger_protected.level = logger_severity.nil? ? Logger::DEBUG : logger_severity
      else
        @logger_protected = logger
        @logger_protected.level = logger_severity unless logger_severity.nil?
        logger.warn('Deprecated: "logger" was set on new! Please use "on_logging_event" instead.')
      end

      # initialize as master process
      @is_forked = false
      # no forked worker processes
      @workers = []

      # list of TCPServers
      @tcp_servers = []
      # list of running threads
      @tcp_server_threads = []

      # lists for connections and thread management
      @connections = []
      @processings = []
      @connections_mutex = Mutex.new
      @connections_cv = ConditionVariable.new

      # settings

      # build array of ports
      # split string into array to instantiate multiple servers
      @ports = ports.to_s.delete(' ').split(',')
      # check for at least one port specification
      raise 'Missing port(s) to bind service(s) to!' if @ports.empty?
      # check that not also a '' empty item for port is added to the list
      raise 'Do not use empty value "" for port(s). Please use specific port(s)!' if @ports.include?('')

      # build array of hosts
      # split string into array to instantiate multiple servers
      @hosts = hosts.to_s.delete(' ').split(',')
      #
      # Check source of TCPServer.c at https://github.com/ruby/ruby/blob/trunk/ext/socket/tcpserver.c#L25-L31
      # * Internally, TCPServer.new calls getaddrinfo() function to obtain ip_addresses.
      # * If getaddrinfo() returns multiple ip_addresses,
      # * TCPServer.new TRIES to create a server socket for EACH address and RETURNS FIRST one that is SUCCESSFUL.
      #
      # So for that it was a small portion of luck which address had been used then.
      # We won't support that magic anymore. If wish to bind on all local ip_addresses
      # and interfaces, use new "*" wildcard, otherwise specify ip_addresses and / or hostnames
      #
      # raise exception when found empty or inner empty hosts specification like "" or "a.b.c.d,,e.f.g.h", guess miss-coding
      raise 'No hosts defined! Please use specific hostnames and / or ip_addresses or "*" for wildcard!' if @hosts.empty?
      raise 'Detected an empty identifier in given hosts! Please use specific hostnames and / or ip_addresses or "*" for wildcard!' if @hosts.include?('')

      # build array of addresses for ip_addresses and ports to use
      @addresses = []
      @hosts.each_with_index do |host, index|
        # resolv ip_addresses for host if not wildcard / all hosts
        # if host is "*" wildcard (all) interfaces are used
        # otherwise it will be bind to the found host ip_addresses
        if host == '*'
          ip_addresses_for_host = []
          Socket.ip_address_list.each do |a|
            # test for all local valid ipv4 and ipv6 ip_addresses
            # check question on stackoverflow for details
            # https://stackoverflow.com/questions/59770803/identify-all-relevant-ip-addresses-from-ruby-socket-ip-address-list
            ip_addresses_for_host << a.ip_address if \
              (a.ipv4? &&
                (a.ipv4_loopback? || a.ipv4_private? ||
                 !(a.ipv4_loopback? || a.ipv4_private? || a.ipv4_multicast?)
                )
              ) ||
              (a.ipv6? &&
                (a.ipv6_loopback? || a.ipv6_unique_local? ||
                 !(a.ipv6_loopback? || a.ipv6_unique_local? || a.ipv6_linklocal? || a.ipv6_multicast? || a.ipv6_sitelocal? ||
                   a.ipv6_mc_global? || a.ipv6_mc_linklocal? || a.ipv6_mc_nodelocal? || a.ipv6_mc_orglocal? || a.ipv6_mc_sitelocal? ||
                   a.ipv6_v4compat? || a.ipv6_v4mapped? || a.ipv6_unspecified?)
                )
              )
          end
        else
          ip_addresses_for_host = Resolv.new.getaddresses(host).uniq
        end
        # get ports for that host entry
        # if ports at index are not specified, use last item
        # of ports array. if multiple ports specified by
        # item like 2525:3535:4545, then all ports will be instantiated
        ports_for_host = (index < @ports.length ? @ports[index] : @ports.last).to_s.split(':')
        # append combination of ip_address and ports to the list of serving addresses
        ip_addresses_for_host.each do |ip_address|
          ports_for_host.each do |port|
            @addresses << "#{ip_address}:#{port}"
          end
        end
      end

      # read pre_fork
      @pre_fork = pre_fork
      raise 'Number of processes to pre-fork (pre_fork) must be zero or a positive integer greater than 1!' unless @pre_fork.is_a?(Integer) && (@pre_fork.zero? || pre_fork?)
      # read max_processings
      @max_processings = max_processings
      raise 'Number of simultaneous processings (max_processings) must be a positive integer!' unless @max_processings.is_a?(Integer) && @max_processings.positive?
      # check max_connections
      @max_connections = max_connections
      raise 'Number of concurrent connections (max_connections) must be nil or a positive integer!' unless @max_connections.nil? || (@max_connections.is_a?(Integer) && @max_connections.positive?)
      raise 'Number of concurrent connections (max_connections) is lower than number of simultaneous processings (max_processings)!' if @max_connections && @max_connections < @max_processings

      # check for crlf mode
      @crlf_mode = crlf_mode.nil? ? DEFAULT_CRLF_MODE : crlf_mode
      raise "Unknown CRLF mode #{@crlf_mode} was given!" unless CRLF_MODES.include?(@crlf_mode)

      # always prevent auto resolving hostnames to prevent a delay on socket connect
      BasicSocket.do_not_reverse_lookup = true
      # do reverse lookups manually if enabled by io.addr and io.peeraddr
      @do_dns_reverse_lookup = do_dns_reverse_lookup.nil? ? true : do_dns_reverse_lookup

      # io and buffer settings
      @io_cmd_timeout = io_cmd_timeout.nil? ? DEFAULT_IO_CMD_TIMEOUT : io_cmd_timeout
      @io_buffer_chunk_size = io_buffer_chunk_size.nil? ? DEFAULT_IO_BUFFER_CHUNK_SIZE : io_buffer_chunk_size
      @io_buffer_max_size = io_buffer_max_size.nil? ? DEFAULT_IO_BUFFER_MAX_SIZE : io_buffer_max_size

      # smtp extensions
      @pipelining_extension = pipelining_extension.nil? ? DEFAULT_PIPELINING_EXTENSION_ENABLED : pipelining_extension
      @internationalization_extensions = internationalization_extensions.nil? ? DEFAULT_INTERNATIONALIZATION_EXTENSIONS_ENABLED : internationalization_extensions

      # check for authentication
      @auth_mode = auth_mode.nil? ? DEFAULT_AUTH_MODE : auth_mode
      raise "Unknown authentication mode #{@auth_mode} was given!" unless AUTH_MODES.include?(@auth_mode)

      # check for encryption
      @encrypt_mode = tls_mode.nil? ? DEFAULT_ENCRYPT_MODE : tls_mode
      raise "Unknown encryption mode #{@encrypt_mode} was given!" unless ENCRYPT_MODES.include?(@encrypt_mode)
      # SSL transport layer for STARTTLS
      if @encrypt_mode == :TLS_FORBIDDEN
        @tls = nil
      else
        # try to load openssl gem now
        begin
          require 'openssl'
        rescue LoadError
        end
        # check for openssl gem when enabling  TLS / SSL
        raise 'The openssl library gem is not installed!' unless defined?(OpenSSL)
        # check for given CN and SAN
        if tls_cert_cn.nil?
          # build generic set of "valid" self signed certificate CN and SAN
          # using all given hosts and detected ip_addresses but not "*" wildcard
          tls_cert_san = ([] + @hosts + @addresses.map { |address| address.rpartition(':').first }).uniq
          tls_cert_san.delete('*')
          # build generic CN based on first SAN
          if tls_cert_san.first.match?(/^(127\.0?0?0\.0?0?0\.0?0?1|::1|localhost)$/i)
            # used generic localhost.local
            tls_cert_cn = 'localhost.local'
          else
            # use first element from detected hosts and ip_addresses
            # drop that element from SAN
            tls_cert_cn = tls_cert_san.first
            tls_cert_san.slice!(0)
          end
        else
          tls_cert_cn = tls_cert_cn.to_s.strip
          tls_cert_san = tls_cert_san.to_s.delete(' ').split(',')
        end
        # create ssl transport service
        @tls = TlsTransport.new(tls_cert_path, tls_key_path, tls_ciphers, tls_methods, tls_cert_cn, tls_cert_san, @logger)
      end
    end

    # event on LOGGING
    # the exposed logger property is from class MidiSmtpServer::ForwardingLogger
    # and pushes any logging message to this on_logging_event.
    # if logging occurs from inside session, the _ctx should be not nil
    # if logging occurs from an error, the err object should be filled
    def on_logging_event(_ctx, severity, msg, err: nil)
      case severity
        when Logger::INFO
          @logger_protected.info(msg)
        when Logger::WARN
          @logger_protected.warn(msg)
        when Logger::ERROR
          @logger_protected.error(msg)
        when Logger::FATAL
          @logger_protected.fatal(msg)
          err.backtrace.each { |log| @logger_protected.fatal("#{log}") }
        else
          @logger_protected.debug(msg)
      end
    end

    # event on CONNECTION
    # you may change the ctx[:server][:local_response] and
    # you may change the ctx[:server][:helo_response] in here so
    # that these will be used as local welcome and greeting strings
    # the values are not allowed to return CR nor LF chars and will be stripped
    def on_connect_event(ctx)
      on_logging_event(ctx, Logger::DEBUG, "Client connect from #{ctx[:server][:remote_ip]}:#{ctx[:server][:remote_port]} to #{ctx[:server][:local_ip]}:#{ctx[:server][:local_port]}")
    end

    # event before DISCONNECT
    def on_disconnect_event(ctx)
      on_logging_event(ctx, Logger::DEBUG, "Client disconnect from #{ctx[:server][:remote_ip]}:#{ctx[:server][:remote_port]} on #{ctx[:server][:local_ip]}:#{ctx[:server][:local_port]}")
    end

    # event on HELO/EHLO
    # you may change the ctx[:server][:helo_response] in here so
    # that this will be used as greeting string
    # the value is not allowed to return CR nor LF chars and will be stripped
    def on_helo_event(ctx, helo_data) end

    # check the authentication on AUTH
    # if any value returned, that will be used for ongoing processing
    # otherwise the original value will be used for authorization_id
    def on_auth_event(ctx, authorization_id, authentication_id, authentication)
      # if authentication is used, override this event
      # and implement your own user management.
      # otherwise all authentications are blocked per default
      on_logging_event(ctx, Logger::DEBUG, "Deny access from #{ctx[:server][:remote_ip]}:#{ctx[:server][:remote_port]} for #{authentication_id}" + (authorization_id == '' ? '' : "/#{authorization_id}") + " with #{authentication}")
      raise Smtpd535Exception
    end

    # check the status of authentication for a given context
    def authenticated?(ctx)
      ctx[:server][:authenticated] && !ctx[:server][:authenticated].to_s.empty?
    end

    # check the status of encryption for a given context
    def encrypted?(ctx)
      ctx[:server][:encrypted] && !ctx[:server][:encrypted].to_s.empty?
    end

    # get address send in MAIL FROM
    # if any value returned, that will be used for ongoing processing
    # otherwise the original value will be used
    def on_mail_from_event(ctx, mail_from_data) end

    # get each address send in RCPT TO
    # if any value returned, that will be used for ongoing processing
    # otherwise the original value will be used
    def on_rcpt_to_event(ctx, rcpt_to_data) end

    # event when beginning with message DATA
    def on_message_data_start_event(ctx) end

    # event while receiving message DATA
    def on_message_data_receiving_event(ctx) end

    # event when headers are received while receiving message DATA
    def on_message_data_headers_event(ctx) end

    # get each message after DATA <message>
    def on_message_data_event(ctx) end

    # event when process_line identifies an unknown command line
    # allows to abort sessions for a series of unknown activities to
    # prevent denial of service attacks etc.
    def on_process_line_unknown_event(_ctx, _line)
      # per default we encounter an error
      raise Smtpd500Exception
    end

    protected

    # Prepare all listeners for all hosts
    def create_service
      raise 'Service was already started' unless stopped?

      # set flag to signal shutdown by stop / shutdown command
      @shutdown = false

      # instantiate the service for all @addresses (ip_address:port)
      @addresses.each do |address|
        # break address into ip_address and port and serve service
        ip_address = address.rpartition(':').first
        port = address.rpartition(':').last
        create_service_on_ip_address_and_port(ip_address, port)
      end
    end

    # Prepare a listener on single ip_address and port
    def create_service_on_ip_address_and_port(ip_address, port)
      # log information
      logger.info("Starting service on #{ip_address}:#{port}")
      # check that there is a specific ip_address defined
      raise 'Unable to start TCP listener on missing or empty ip_address!' if ip_address.empty?
      # instantiate the service for ip_address and port
      tcp_server = TCPServer.new(ip_address, port)
      # append this server to the list of TCPServers
      @tcp_servers << tcp_server
    end

    # Close and remove the given tcp_server
    def remove_tcp_server(tcp_server)
      begin
        # drop the service
        tcp_server.close
        # remove from list
        @tcp_servers.delete(tcp_server)
      rescue StandardError
        # ignore any error from here
      end
    end

    # Join with the server thread(s)
    # before joining the server threads, wait optionally a few seconds
    # to let the service(s) come up
    def join_threads(sleep_seconds_before_join: 1)
      # wait some seconds before joining the upcoming threads
      # and check that all TCPServers got one thread
      while (@tcp_server_threads.length < @tcp_servers.length) && sleep_seconds_before_join.positive?
        sleep_seconds_before_join -= 1
        sleep 1
      end
      # try to join any thread
      begin
        @tcp_server_threads.each(&:join)

        # catch ctrl-c to stop service
      rescue Interrupt
      end
    end

    # Create and attach threads to all listeners
    def attach_threads
      # loop for all TCPServers listener
      @tcp_servers.each { |tcp_server| attach_thread(tcp_server) }
    end

    # Create and attach a thread to a listener
    def attach_thread(tcp_server)
      # run thread until shutdown
      @tcp_server_threads << Thread.new do
        begin
          # always check for shutdown request
          until shutdown?
            # get new client and start additional thread
            # to handle client process
            client = tcp_server.accept
            Thread.new(client) do |io|
              # add to list of connections
              @connections << Thread.current
              # handle connection
              begin
                # initialize a session storage hash
                Thread.current[:session] = {}
                # process smtp service on io socket
                io = serve_client(Thread.current[:session], io)
                # save returned io value due to maybe
                # established ssl io socket
              rescue SmtpdStopConnectionException
                # ignore this exception due to service shutdown
              rescue StandardError => e
                # log fatal error while handling connection
                on_logging_event(nil, Logger::FATAL, "#{e} (#{e.class})".strip, err: e.clone)
              ensure
                begin
                  # always gracefully shutdown connection.
                  # if the io object was overridden by the
                  # result from serve_client() due to ssl
                  # io, the ssl + io socket will be closed
                  io.close
                rescue StandardError
                  # ignore any exception from here
                end
                # remove closed session from connections
                @connections_mutex.synchronize do
                  # drop this thread from connections
                  @connections.delete(Thread.current)
                  # drop this thread from processings
                  @processings.delete(Thread.current)
                  # signal mutex for next waiting thread
                  @connections_cv.signal
                end
              end
            end
          end
        rescue SmtpdStopServiceException
          # ignore this exception due to service shutdown
        rescue StandardError => e
          # log fatal error while starting new thread
          on_logging_event(nil, Logger::FATAL, "#{e} (#{e.class})".strip, err: e.clone)
        ensure
          # proper connection down?
          if shutdown?
            # wait for finishing opened connections
            @connections_mutex.synchronize do
              @connections_cv.wait(@connections_mutex) until @connections.empty?
            end
          else
            # drop any open session immediately
            @connections.each { |c| c.raise SmtpdStopConnectionException }
          end
          # remove this thread from list
          @tcp_server_threads.delete(Thread.current)
        end
      end
    end

    # handle connection
    def serve_client(session, io)
      # handle connection
      begin
        begin
          # ON CONNECTION
          # 220 <domain> Service ready
          # 421 <domain> Service not available, closing transmission channel
          # Reset and initialize message
          process_reset_session(session, connection_initialize: true)

          # get local address info
          _, session[:ctx][:server][:local_port], session[:ctx][:server][:local_host], session[:ctx][:server][:local_ip] = @do_dns_reverse_lookup ? io.addr(:hostname) : io.addr(:numeric)
          # get remote partner hostname and address
          _, session[:ctx][:server][:remote_port], session[:ctx][:server][:remote_host], session[:ctx][:server][:remote_ip] = @do_dns_reverse_lookup ? io.peeraddr(:hostname) : io.peeraddr(:numeric)

          # save connection date/time
          session[:ctx][:server][:connected] = Time.now.utc

          # build and save the local welcome and greeting response strings
          session[:ctx][:server][:local_response] = "#{session[:ctx][:server][:local_host]} says welcome!"
          session[:ctx][:server][:helo_response] = "#{session[:ctx][:server][:local_host]} at your service!"

          # check if we want to let this remote station connect us
          on_connect_event(session[:ctx])

          # drop connection (respond 421) if too busy
          raise Smtpd421Exception, 'Abort connection while too busy, exceeding max_connections!' if max_connections && connections > max_connections

          # check active processings for new client
          @connections_mutex.synchronize do
            # when processings exceed maximum number of simultaneous allowed processings, then wait for next free slot
            @connections_cv.wait(@connections_mutex) until processings < max_processings
          end

          # append this to list of processings
          @processings << Thread.current

          # reply local welcome message
          output = +"220 #{session[:ctx][:server][:local_response].to_s.strip}\r\n"

          # log and show to client
          on_logging_event(session[:ctx], Logger::DEBUG, +'>>> ' << output)
          io.print output unless io.closed?

          # initialize \r\n for line_break, this is used for CRLF_ENSURE and CRLF_STRICT and mark as mutable
          line_break = +"\r\n"

          # initialize io_buffer for input data and mark as mutable
          io_buffer = +''

          # initialize io_buffer_line_lf index
          io_buffer_line_lf = nil

          # initialize timeout timestamp
          timestamp_timeout = Time.now.to_i

          # while input data handle communication
          loop do
            # test if STARTTLS sequence
            if session[:cmd_sequence] == :CMD_STARTTLS
              # start ssl tunnel
              io = @tls.start(io)
              # save enabled tls
              session[:ctx][:server][:encrypted] = Time.now.utc
              # set sequence back to HELO/EHLO
              session[:cmd_sequence] = :CMD_HELO
              # reset timeout timestamp
              timestamp_timeout = Time.now.to_i
            end

            # read input data from Socket / SSLSocket into io_buffer
            # by non-blocking action until \n is found
            begin
              unless io_buffer_line_lf
                # check for timeout on IO
                raise SmtpdIOTimeoutException if @io_cmd_timeout && Time.now.to_i - timestamp_timeout > @io_cmd_timeout
                # read chunks of input data until line-feed
                io_buffer << io.read_nonblock(@io_buffer_chunk_size)
                # check for buffer size
                raise SmtpdIOBufferOverrunException if @io_buffer_max_size && io_buffer.length > @io_buffer_max_size
                # check for lf in current io_buffer
                io_buffer_line_lf = io_buffer.index("\n")
              end

            # ignore exception when no input data is available yet
            rescue IO::WaitReadable
              # but wait a few moment to slow down system utilization
              sleep 0.1
            end

            # check if io_buffer is filled and contains already a line-feed
            while io_buffer_line_lf
              # extract line (containing \n) from io_buffer and slice io_buffer
              line = io_buffer.slice!(0, io_buffer_line_lf + 1)

              # check for next line-feed already in io_buffer
              io_buffer_line_lf = io_buffer.index("\n")

              # process commands and handle special SmtpdExceptions
              begin
                # check for pipelining extension or violation
                raise Smtpd500PipeliningException unless @pipelining_extension || !io_buffer_line_lf || (session[:cmd_sequence] == :CMD_DATA)

                # handle input line based on @crlf_mode
                case crlf_mode
                  when :CRLF_ENSURE
                    # remove any \r or \n occurrence from line
                    line.delete!("\r\n")
                    # log line, verbosity based on log severity and command sequence
                    on_logging_event(session[:ctx], Logger::DEBUG, +'<<< ' << line << "\n") if session[:cmd_sequence] != :CMD_DATA

                  when :CRLF_LEAVE
                    # use input line_break for line_break
                    line_break = line[-2..] == "\r\n" ? "\r\n" : "\n"
                    # check to override session crlf info, only when CRLF_LEAVE is used and in DATA mode
                    session[:ctx][:message][:crlf] = line_break if session[:cmd_sequence] == :CMD_DATA
                    # remove any line_break from line
                    line.chomp!
                    # log line, verbosity based on log severity and command sequence
                    on_logging_event(session[:ctx], Logger::DEBUG, +'<<< ' << line.gsub("\r", '[\r]') << "\n") if session[:cmd_sequence] != :CMD_DATA

                  when :CRLF_STRICT
                    # check line ends up by \r\n
                    raise Smtpd500CrLfSequenceException unless line[-2..] == "\r\n"
                    # remove any line_break from line
                    line.chomp!
                    # check line for additional \r
                    raise Smtpd500Exception, 'Line contains additional CR chars!' if line.index("\r")
                    # log line, verbosity based on log severity and command sequence
                    on_logging_event(session[:ctx], Logger::DEBUG, +'<<< ' << line << "\n") if session[:cmd_sequence] != :CMD_DATA
                end

                # process line and mark output as mutable
                output = +process_line(session, line, line_break)

              # defined abort channel exception
              rescue Smtpd421Exception => e
                # just re-raise this exception and exit loop and communication
                raise

              # defined SmtpdException
              rescue SmtpdException => e
                # inc number of detected exceptions during this session
                session[:ctx][:server][:exceptions] += 1
                # save clone of error object to context
                session[:ctx][:server][:errors].push(e.clone)
                # log error info if logging
                on_logging_event(session[:ctx], Logger::ERROR, "#{e} (#{e.class})".strip, err: e)
                # get the given smtp dialog result
                output = +"#{e.smtpd_result}"

              # Unknown general Exception during processing
              rescue StandardError => e
                # inc number of detected exceptions during this session
                session[:ctx][:server][:exceptions] += 1
                # save clone of error object to context
                session[:ctx][:server][:errors].push(e.clone)
                # log error info if logging
                on_logging_event(session[:ctx], Logger::ERROR, "#{e} (#{e.class})".strip, err: e)
                # set default smtp server dialog error
                output = +"#{Smtpd500Exception.new.smtpd_result}"
              end

              # check result
              unless output.empty?
                # log smtp dialog // message data is stored separate
                on_logging_event(session[:ctx], Logger::DEBUG, +'>>> ' << output)
                # append line feed
                output << "\r\n"
                # smtp dialog response
                io.print(output) unless io.closed? || shutdown?
              end

              # reset timeout timestamp
              timestamp_timeout = Time.now.to_i
            end

            # check for valid quit or broken communication
            break if (session[:cmd_sequence] == :CMD_QUIT) || io.closed? || shutdown?
          end
          # graceful end of connection
          output = +"221 Service closing transmission channel\r\n"
          # smtp dialog response
          io.print(output) unless io.closed?

        # connection was simply closed / aborted by remote closing socket
        rescue EOFError => e
          # log info but only while debugging otherwise ignore message
          on_logging_event(session[:ctx], Logger::DEBUG, 'Connection lost due abort by client! (EOFError)', err: e)

        rescue StandardError => e
          # inc number of detected exceptions during this session
          session[:ctx][:server][:exceptions] += 1
          # save clone of error object to context
          session[:ctx][:server][:errors].push(e.clone)
          # log error info if logging
          on_logging_event(session[:ctx], Logger::ERROR, "#{e} (#{e.class})".strip, err: e)
          # power down connection
          # ignore IOErrors when sending final smtp abort return code 421
          begin
            output = +"#{Smtpd421Exception.new.smtpd_result}\r\n"
            # smtp dialog response
            io.print(output) unless io.closed?
          rescue StandardError => e
            on_logging_event(session[:ctx], Logger::DEBUG, 'Can\'t send 421 abort code! (IOError)', err: e)
          end
        end

      ensure
        # event for cleanup at end of communication
        on_disconnect_event(session[:ctx])
      end

      # return socket handler, maybe replaced with ssl
      return io
    end

    def process_line(session, line, line_break)
      # check whether in auth challenge modes
      if session[:cmd_sequence] == :CMD_AUTH_PLAIN_VALUES
        # handle authentication
        process_auth_plain(session, line)

      # check whether in auth challenge modes
      elsif session[:cmd_sequence] == :CMD_AUTH_LOGIN_USER
        # handle authentication
        process_auth_login_user(session, line)

      # check whether in auth challenge modes
      elsif session[:cmd_sequence] == :CMD_AUTH_LOGIN_PASS
        # handle authentication
        process_auth_login_pass(session, line)

      # check whether in data or command mode
      elsif session[:cmd_sequence] != :CMD_DATA

        # Handle specific messages from the client
        case line

          when (/^(HELO|EHLO)(\s+.*)?$/i)
            # HELO/EHLO
            # 250 Requested mail action okay, completed
            # 421 <domain> Service not available, closing transmission channel
            # 500 Syntax error, command unrecognised
            # 501 Syntax error in parameters or arguments
            # 504 Command parameter not implemented
            # 521 <domain> does not accept mail [rfc1846]
            # ---------
            # check valid command sequence
            raise Smtpd503Exception if session[:cmd_sequence] != :CMD_HELO
            # handle command
            cmd_data = line.gsub(/^(HELO|EHLO)\ /i, '').strip
            # call event to handle data
            on_helo_event(session[:ctx], cmd_data)
            # if no error raised, append to message hash
            session[:ctx][:server][:helo] = cmd_data
            # set sequence state as RSET
            session[:cmd_sequence] = :CMD_RSET
            # check whether to answer as HELO or EHLO
            case line
              when (/^EHLO/i)
                # rubocop:disable Style/StringConcatenation
                # reply supported extensions
                return "250-#{session[:ctx][:server][:helo_response].to_s.strip}\r\n" +
                       # respond with 8BITMIME extension
                       (@internationalization_extensions ? "250-8BITMIME\r\n" : '') +
                       # respond with SMTPUTF8 extension
                       (@internationalization_extensions ? "250-SMTPUTF8\r\n" : '') +
                       # respond with PIPELINING if enabled
                       (@pipelining_extension ? "250-PIPELINING\r\n" : '') +
                       # respond with AUTH extensions if enabled
                       (@auth_mode == :AUTH_FORBIDDEN ? '' : "250-AUTH LOGIN PLAIN\r\n") +
                       # respond with STARTTLS if available and not already enabled
                       (@encrypt_mode == :TLS_FORBIDDEN || encrypted?(session[:ctx]) ? '' : "250-STARTTLS\r\n") +
                       '250 OK'
                # rubocop:enable all
              else
                # reply ok only
                return "250 OK #{session[:ctx][:server][:helo_response].to_s.strip}".strip
            end

          when /^STARTTLS\s*$/i
            # STARTTLS
            # 220 Ready to start TLS
            # 454 TLS not available
            # 501 Syntax error (no parameters allowed)
            # ---------
            # check that encryption is allowed
            raise Smtpd500Exception if @encrypt_mode == :TLS_FORBIDDEN
            # check valid command sequence
            raise Smtpd503Exception if session[:cmd_sequence] == :CMD_HELO
            # check initialized TlsTransport object
            raise Tls454Exception unless @tls
            # check valid command sequence
            raise Smtpd503Exception if encrypted?(session[:ctx])
            # set sequence for next command input
            session[:cmd_sequence] = :CMD_STARTTLS
            # return with new service ready message
            return '220 Ready to start TLS'

          when (/^AUTH(\s+)((LOGIN|PLAIN)(\s+[A-Z0-9=]+)?|CRAM-MD5)\s*$/i)
            # AUTH
            # 235 Authentication Succeeded
            # 432 A password transition is needed
            # 454 Temporary authentication failure
            # 500 Authentication Exchange line is too long
            # 530 Authentication required
            # 534 Authentication mechanism is too weak
            # 535 Authentication credentials invalid
            # 538 Encryption required for requested authentication mechanism
            # ---------
            # check that authentication is allowed
            raise Smtpd500Exception if @auth_mode == :AUTH_FORBIDDEN
            # check valid command sequence
            raise Smtpd503Exception if session[:cmd_sequence] != :CMD_RSET
            # check that encryption is enabled if necessary
            raise Tls530Exception if @encrypt_mode == :TLS_REQUIRED && !encrypted?(session[:ctx])
            # check that not already authenticated
            raise Smtpd503Exception if authenticated?(session[:ctx])
            # handle command line
            auth_data = line.gsub(/^AUTH\ /i, '').strip.gsub(/\s+/, ' ').split
            # handle auth command
            case auth_data[0]

              when (/PLAIN/i)
                # check if only command was given
                if auth_data.length == 1
                  # set sequence for next command input
                  session[:cmd_sequence] = :CMD_AUTH_PLAIN_VALUES
                  # response code include post ending with a space
                  return '334 '
                else
                  # handle authentication with given auth_id and password
                  process_auth_plain(session, auth_data.length == 2 ? auth_data[1] : [])
                end

              when (/LOGIN/i)
                # check if auth_id was sent too
                case auth_data.length

                  when 1
                    # reset auth_challenge
                    session[:auth_challenge] = {}
                    # set sequence for next command input
                    session[:cmd_sequence] = :CMD_AUTH_LOGIN_USER
                    # response code with request for Username
                    return +'' << '334 ' << Base64.strict_encode64('Username:')

                  when 2
                    # handle next sequence
                    process_auth_login_user(session, auth_data[1])

                  else
                    raise Smtpd500Exception
                end

              # not supported in case of also unencrypted data delivery
              # instead of supporting password encryption only, we will
              # provide optional SMTPS service instead
              # read discussion on https://github.com/4commerce-technologies-AG/midi-smtp-server/issues/3#issuecomment-126898711
              #
              # when (/CRAM-MD5/i)
              #   raise Smtpd500Exception

              else
                # unknown auth method
                raise Smtpd500Exception

            end

          when (/^NOOP\s*$/i)
            # NOOP
            # 250 Requested mail action okay, completed
            # 421 <domain> Service not available, closing transmission channel
            # 500 Syntax error, command unrecognised
            return '250 OK'

          when (/^RSET\s*$/i)
            # RSET
            # 250 Requested mail action okay, completed
            # 421 <domain> Service not available, closing transmission channel
            # 500 Syntax error, command unrecognised
            # 501 Syntax error in parameters or arguments
            # ---------
            # check valid command sequence
            raise Smtpd503Exception if session[:cmd_sequence] == :CMD_HELO
            # check that encryption is enabled if necessary
            raise Tls530Exception if @encrypt_mode == :TLS_REQUIRED && !encrypted?(session[:ctx])
            # handle command
            process_reset_session(session)
            return '250 OK'

          when (/^QUIT\s*$/i)
            # QUIT
            # 221 <domain> Service closing transmission channel
            # 500 Syntax error, command unrecognised
            session[:cmd_sequence] = :CMD_QUIT
            return ''

          when (/^MAIL FROM:/i)
            # MAIL
            # 250 Requested mail action okay, completed
            # 421 <domain> Service not available, closing transmission channel
            # 451 Requested action aborted: local error in processing
            # 452 Requested action not taken: insufficient system storage
            # 500 Syntax error, command unrecognised
            # 501 Syntax error in parameters or arguments
            # 552 Requested mail action aborted: exceeded storage allocation
            # ---------
            # check valid command sequence
            raise Smtpd503Exception if session[:cmd_sequence] != :CMD_RSET
            # check that encryption is enabled if necessary
            raise Tls530Exception if @encrypt_mode == :TLS_REQUIRED && !encrypted?(session[:ctx])
            # check that authentication is enabled if necessary
            raise Smtpd530Exception if @auth_mode == :AUTH_REQUIRED && !authenticated?(session[:ctx])
            # handle command
            cmd_data = line.gsub(/^MAIL FROM:/i, '').strip
            # check for BODY= parameter
            case cmd_data
              # test for explicit 7bit
              when (/\sBODY=7BIT(\s|$)/i)
                # raise exception if not supported
                raise Smtpd501Exception unless @internationalization_extensions
                # save info about encoding
                session[:ctx][:envelope][:encoding_body] = '7bit'
              # test for 8bit
              when (/\sBODY=8BITMIME(\s|$)/i)
                # raise exception if not supported
                raise Smtpd501Exception unless @internationalization_extensions
                # save info about encoding
                session[:ctx][:envelope][:encoding_body] = '8bitmime'
              # test for unknown encoding
              when (/\sBODY=.*$/i)
                # unknown BODY encoding
                raise Smtpd501Exception
            end
            # check for SMTPUTF8 parameter
            case cmd_data
              # test for explicit 7bit
              when (/\sSMTPUTF8(\s|$)/i)
                # raise exception if not supported
                raise Smtpd501Exception unless @internationalization_extensions
                # save info about encoding
                session[:ctx][:envelope][:encoding_utf8] = 'utf8'
            end
            # drop any BODY= and SMTPUTF8 content
            cmd_data = cmd_data.gsub(/\sBODY=(7BIT|8BITMIME)/i, '').gsub(/\sSMTPUTF8/i, '').strip if @internationalization_extensions
            # call event to handle data
            return_value = on_mail_from_event(session[:ctx], cmd_data)
            if return_value
              # overwrite data with returned value
              cmd_data = return_value
            end
            # if no error raised, append to message hash
            session[:ctx][:envelope][:from] = cmd_data
            # set sequence state
            session[:cmd_sequence] = :CMD_MAIL
            # reply ok
            return '250 OK'

          when (/^RCPT TO:/i)
            # RCPT
            # 250 Requested mail action okay, completed
            # 251 User not local; will forward to <forward-path>
            # 421 <domain> Service not available, closing transmission channel
            # 450 Requested mail action not taken: mailbox unavailable
            # 451 Requested action aborted: local error in processing
            # 452 Requested action not taken: insufficient system storage
            # 500 Syntax error, command unrecognised
            # 501 Syntax error in parameters or arguments
            # 503 Bad sequence of commands
            # 521 <domain> does not accept mail [rfc1846]
            # 550 Requested action not taken: mailbox unavailable
            # 551 User not local; please try <forward-path>
            # 552 Requested mail action aborted: exceeded storage allocation
            # 553 Requested action not taken: mailbox name not allowed
            # ---------
            # check valid command sequence
            raise Smtpd503Exception unless [:CMD_MAIL, :CMD_RCPT].include?(session[:cmd_sequence])
            # check that encryption is enabled if necessary
            raise Tls530Exception if @encrypt_mode == :TLS_REQUIRED && !encrypted?(session[:ctx])
            # check that authentication is enabled if necessary
            raise Smtpd530Exception if @auth_mode == :AUTH_REQUIRED && !authenticated?(session[:ctx])
            # handle command
            cmd_data = line.gsub(/^RCPT TO:/i, '').strip
            # call event to handle data
            return_value = on_rcpt_to_event(session[:ctx], cmd_data)
            if return_value
              # overwrite data with returned value
              cmd_data = return_value
            end
            # if no error raised, append to message hash
            session[:ctx][:envelope][:to] << cmd_data
            # set sequence state
            session[:cmd_sequence] = :CMD_RCPT
            # reply ok
            return '250 OK'

          when (/^DATA\s*$/i)
            # DATA
            # 354 Start mail input; end with <CRLF>.<CRLF>
            # 250 Requested mail action okay, completed
            # 421 <domain> Service not available, closing transmission channel received data
            # 451 Requested action aborted: local error in processing
            # 452 Requested action not taken: insufficient system storage
            # 500 Syntax error, command unrecognised
            # 501 Syntax error in parameters or arguments
            # 503 Bad sequence of commands
            # 552 Requested mail action aborted: exceeded storage allocation
            # 554 Transaction failed
            # ---------
            # check valid command sequence
            raise Smtpd503Exception if session[:cmd_sequence] != :CMD_RCPT
            # check that encryption is enabled if necessary
            raise Tls530Exception if @encrypt_mode == :TLS_REQUIRED && !encrypted?(session[:ctx])
            # check that authentication is enabled if necessary
            raise Smtpd530Exception if @auth_mode == :AUTH_REQUIRED && !authenticated?(session[:ctx])
            # handle command
            # set sequence state
            session[:cmd_sequence] = :CMD_DATA
            # save incoming UTC time
            session[:ctx][:message][:received] = Time.now.utc
            # reply ok / proceed with message data
            return '354 Enter message, ending with "." on a line by itself'

          else
            # If we somehow get to this point then
            # allow handling of unknown command line
            on_process_line_unknown_event(session[:ctx], line)
        end

      else
        # If we are in date mode then ...

        # call event to signal beginning of message data transfer
        on_message_data_start_event(session[:ctx]) unless session[:ctx][:message][:data][0]

        # ... and the entire new message data (line) does NOT consists
        # solely of a period (.) on a line by itself then we are being
        # told to continue data mode and the command sequence state
        # will stay on :CMD_DATA
        unless line == '.'
          # remove a preceding first dot as defined by RFC 5321 (section-4.5.2)
          line.slice!(0) if line[0] == '.'

          # if received an empty line the first time, that identifies
          # end of headers.
          unless session[:ctx][:message][:headers][0] || line[0]
            # change flag to do not signal this again for the
            # active message data transmission
            session[:ctx][:message][:headers] = true.to_s
            # call event to process received headers
            on_message_data_headers_event(session[:ctx])
          end

          # we need to add the new message data (line) to the message
          # and make sure to add CR LF as defined by RFC
          session[:ctx][:message][:data] << line << line_break

          # call event to inspect message data while recording line by line
          # e.g. abort while receiving too big incoming mail or
          # create a teergrube for spammers etc.
          on_message_data_receiving_event(session[:ctx])

          # just return and stay on :CMD_DATA
          return ''
        end

        # otherwise the entire new message data (line) consists
        # solely of a period on a line by itself then we are being
        # told to finish data mode

        # remove last CR LF pair or single LF in buffer
        session[:ctx][:message][:data].chomp!
        # save delivered UTC time
        session[:ctx][:message][:delivered] = Time.now.utc
        # save bytesize of message data
        session[:ctx][:message][:bytesize] = session[:ctx][:message][:data].bytesize
        # call event to process message
        begin
          on_message_data_event(session[:ctx])
          return '250 Requested mail action okay, completed'

        # test for SmtpdException
        rescue SmtpdException
          # just re-raise exception set by app
          raise

        # test all other Exceptions
        rescue StandardError => e
          # send correct aborted message to smtp dialog
          raise Smtpd451Exception, e

        ensure
          # always start with empty values after finishing incoming message
          # and rset command sequence
          process_reset_session(session)
        end

      end
    end

    # reset the context of current smtpd dialog
    def process_reset_session(session, connection_initialize: false)
      # set active command sequence info
      session[:cmd_sequence] = connection_initialize ? :CMD_HELO : :CMD_RSET
      # drop any auth challenge
      session[:auth_challenge] = {}
      # test existing of :ctx hash
      session[:ctx] || session[:ctx] = {}
      # reset server values (only on connection start)
      if connection_initialize
        # create or rebuild :ctx hash
        # and mark strings as mutable
        session[:ctx].merge!(
          server: {
            local_host: +'',
            local_ip: +'',
            local_port: +'',
            local_response: +'',
            remote_host: +'',
            remote_ip: +'',
            remote_port: +'',
            helo: +'',
            helo_response: +'',
            connected: +'',
            exceptions: 0,
            errors: [],
            authorization_id: +'',
            authentication_id: +'',
            authenticated: +'',
            encrypted: +''
          }
        )
      end
      # reset envelope values
      session[:ctx].merge!(
        envelope: {
          from: +'',
          to: [],
          encoding_body: +'',
          encoding_utf8: +''
        }
      )
      # reset message data
      session[:ctx].merge!(
        message: {
          received: -1,
          delivered: -1,
          bytesize: -1,
          headers: +'',
          crlf: +"\r\n",
          data: +''
        }
      )
    end

    # handle plain authentication
    def process_auth_plain(session, encoded_auth_response)
      begin
        # extract auth id (and password)
        auth_values = Base64.decode64(encoded_auth_response).split("\x00")
        # check for valid credentials parameters
        raise Smtpd500Exception unless auth_values.length == 3
        # call event function to test credentials
        return_value = on_auth_event(session[:ctx], auth_values[0], auth_values[1], auth_values[2])
        if return_value
          # overwrite data with returned value as authorization id
          auth_values[0] = return_value
        end
        # save authentication information to ctx
        session[:ctx][:server][:authorization_id] = auth_values[0].to_s.empty? ? auth_values[1] : auth_values[0]
        session[:ctx][:server][:authentication_id] = auth_values[1]
        session[:ctx][:server][:authenticated] = Time.now.utc
        # response code
        return '235 OK'

      ensure
        # whatever happens in this check, reset next sequence
        session[:cmd_sequence] = :CMD_RSET
      end
    end

    def process_auth_login_user(session, encoded_auth_response)
      # save challenged auth_id
      session[:auth_challenge][:authorization_id] = ''
      session[:auth_challenge][:authentication_id] = Base64.decode64(encoded_auth_response)
      # set sequence for next command input
      session[:cmd_sequence] = :CMD_AUTH_LOGIN_PASS
      # response code with request for Password
      return +'' << '334 ' << Base64.strict_encode64('Password:')
    end

    def process_auth_login_pass(session, encoded_auth_response)
      begin
        # extract auth id (and password)
        auth_values = [
          session[:auth_challenge][:authorization_id],
          session[:auth_challenge][:authentication_id],
          Base64.decode64(encoded_auth_response)
        ]
        # check for valid credentials
        return_value = on_auth_event(session[:ctx], auth_values[0], auth_values[1], auth_values[2])
        if return_value
          # overwrite data with returned value as authorization id
          auth_values[0] = return_value
        end
        # save authentication information to ctx
        session[:ctx][:server][:authorization_id] = auth_values[0].to_s.empty? ? auth_values[1] : auth_values[0]
        session[:ctx][:server][:authentication_id] = auth_values[1]
        session[:ctx][:server][:authenticated] = Time.now.utc
        # response code
        return '235 OK'

      ensure
        # whatever happens in this check, reset next sequence
        session[:cmd_sequence] = :CMD_RSET
        # and reset auth_challenge
        session[:auth_challenge] = {}
      end
    end

  end

end
