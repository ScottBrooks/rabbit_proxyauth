{application, rabbit_proxyauth,
  [{description, "Proxy Authentication requests"},
   {vsn, "0.0.1"},
   {modules, [
     rabbit_proxyauth,
     rabbit_proxyauth_sup,
     rabbit_proxyauth_worker
   ]},
   {registered, []},
   {mod, {rabbit_proxyauth, []}},
   {env, []},
   {applications, [kernel, stdlib, rabbit, amqp_client, rfc4627_jsonrpc]}]}.
