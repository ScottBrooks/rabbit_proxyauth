require 'rubygems'
require 'mq'
require 'json'

def send_reply(reply, reply_to)
  MQ.direct("").publish(reply.to_json, :key=>reply_to)
end

def handle_login(data)
  {"code"=>200, "id"=>data["id"]}
end

def handle_vhost(data)
  {"code"=>200, "id"=>data["id"]}
end

def handle_resource_access(data)
  {"code"=>200, "id"=>data["id"]}
end

def handle(data, reply_to)
  reply = case data["action"]
    when "login"
      handle_login(data)
    when "vhost"
      handle_vhost(data)
    when "resource_access"
      handle_resource_access(data)
  end
  send_reply(reply, reply_to)
end

AMQP.start() do
  puts "Connected"
  MQ.queue('', :auto_delete=>true).bind('proxyauth', :key=>'#').subscribe do |header,msg|
    data = JSON.parse(msg)
    p header
    p msg

    handle(data, header.reply_to)
  end
end
