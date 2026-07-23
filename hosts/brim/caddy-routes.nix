{
  services.caddy.settings.apps.http.servers.default = {
    routes = [
      {
        match = [ { host = [ "hunt-api.brim.su" ]; } ];
        terminal = true;
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [ { dial = "195.170.194.163:1896"; } ];
          }
        ];
      }
      {
        match = [ { host = [ "pubg-api.brim.su" ]; } ];
        terminal = true;
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [ { dial = "195.170.194.163:2017"; } ];
          }
        ];
      }
      {
        match = [ { host = [ "ip.brim.su" ]; } ];
        terminal = true;
        handle = [
          {
            handler = "static_response";
            headers.Content-Type = [ "text/plain" ];
            body = "{http.request.remote.host}";
          }
        ];
      }
      {
        match = [ { host = [ "git.brim.su" ]; } ];
        terminal = true;
        handle = [
          {
            handler = "static_response";
            status_code = 301; # Moved Permanently
            headers.Location = [ "https://github.com/Whitebrim" ];
          }
        ];
      }
      {
        match = [ { host = [ "tg.brim.su" ]; } ];
        terminal = true;
        handle = [
          {
            handler = "static_response";
            status_code = 301; # Moved Permanently
            headers.Location = [ "https://t.me/Whitebrim" ];
          }
        ];
      }
      {
        match = [ { host = [ "vk.brim.su" ]; } ];
        terminal = true;
        handle = [
          {
            handler = "static_response";
            status_code = 301; # Moved Permanently
            headers.Location = [ "https://vk.com/Whitebrim" ];
          }
        ];
      }
      {
        match = [ { host = [ "letmein.brim.su" ]; } ];
        terminal = true;
        handle = [
          {
            handler = "static_response";
            status_code = 302; # Found
            headers.Location = [
              "https://brimworld.online/s/3447b683-0b35-4ccd-b0cd-2f677ac812f4/doc/anketa-E2ivmU3h16"
            ];
          }
        ];
      }
      {
        match = [ { host = [ "automodpack.brimworld.online" ]; } ];
        terminal = true;
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [ { dial = "localhost:30037"; } ];
          }
        ];
      }
      {
        match = [
          {
            host = [
              "plan.brim.su"
              "plan.brimworld.online"
            ];
          }
        ];
        terminal = true;
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [ { dial = "localhost:8804"; } ];
          }
        ];
      }
      {
        match = [
          {
            host = [
              "map.brim.su"
              "map-vanilla.brim.su"
              "map.brimworld.online"
              "map-vanilla.brimworld.online"
            ];
          }
        ];
        terminal = true;
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [ { dial = "localhost:18080"; } ];
          }
        ];
      }
      {
        match = [
          {
            host = [
              "map-mods.brim.su"
              "map-mods.brimworld.online"
            ];
          }
        ];
        terminal = true;
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [ { dial = "localhost:18081"; } ];
          }
        ];
      }
    ];
  };
}
