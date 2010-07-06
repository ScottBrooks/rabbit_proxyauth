require 'rubygems'
require 'mq'

AMQP.start(:user=>'test') do
  puts "Connected"
  MQ.queue('test').subscribe do |msg|
    p msg
  end
end
