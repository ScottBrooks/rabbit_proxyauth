require 'rubygems'
require 'mq'

def send_reply(reply, reply_to)
  if reply["code"] == 200
    puts "Sending ok to #{reply_to}"
    MQ.direct("").publish("id:#{reply["id"]}\nreply:ok", :key=>reply_to)
  end
end

def handle_login(data)
  {"code"=>200, "id"=>data["id"]}
end

def handle(data, reply_to)
  reply = case data["action"]
    when "login"
      handle_login(data)
  end
  send_reply(reply, reply_to)
end

AMQP.start() do
  puts "Connected"
  MQ.queue('', :auto_delete=>true).bind('proxyauth', :key=>'#').subscribe do |header,msg|
    data = {}

    msg.each_line do |line|
      key,value = line.strip.split(":", 2)
      data[key] = value
    end
    handle(data, header.reply_to)
  end
end
