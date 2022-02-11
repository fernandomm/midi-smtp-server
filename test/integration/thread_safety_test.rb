# frozen_string_literal: true

require 'mail'

# Unit test to check commands without TCP
class ThreadSafetyTest < BaseIntegrationTest

  # initialize before tests
  def setup
    # create some message vars and sources
    super
    # create service instance
    @smtpd = MidiSmtpServerSaveFile.new(
      ports: '5555',
      hosts: '127.0.0.1',
      max_processings: 50,
      do_dns_reverse_lookup: false,
      logger_severity: Logger::ERROR,
      auth_mode: :AUTH_OPTIONAL
    )
    @smtpd.tmp_dir = Dir.mktmpdir
    # start the daemon to run real life integration tests
    @smtpd.start
  end

  def teardown
    # Cleanup directory
    FileUtils.remove_entry @smtpd.tmp_dir

    super
  end

  ### TEST SUITE

  def test_thread_safety_with_multiple_connections
    threads = []

    15.times do |i|
      email = "email#{i}@local.local"

      threads << Thread.new do
        150.times do
          net_smtp_send_mail email, email, @doc_simple_mail, authentication_id: email, password: 'password', tls_enabled: false
        end
      end
    end

    threads.each(&:join)
  end

end
