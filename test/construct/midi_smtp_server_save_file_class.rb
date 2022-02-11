# frozen_string_literal: true

# require the libraries
require 'midi-smtp-server'

class MidiSmtpServerSaveFile < MidiSmtpServer::Smtpd

  attr_accessor :tmp_dir

  def on_auth_event(_ctx, _authorization_id, authentication_id, _authentication)
    authentication_id
  end

  def on_message_data_event(ctx)
    raise 'ctx has data from other connections' if "<#{ctx[:server][:authorization_id]}>" != ctx[:envelope][:from] || ctx[:envelope][:from] != ctx[:envelope][:to].first

    # I/O operations seems to make the issue more reproducible
    File.binwrite(File.join(tmp_dir, "#{ctx[:server][:authorization_id]}-#{SecureRandom.uuid}.msg"), ctx[:message][:data])
  end

end
