# n8n-deploy

Deploy and manage n8n workflows on your Ubuntu server with confidence. This repository provides a battle-tested, secure, and highly available installation script that:

* **Automates Setup**

  * One-click installation of n8n using Docker and Docker Compose
  * Automatic configuration of SSL certificates via Let’s Encrypt
  * Systemd service for seamless startup, shutdown, and auto-restart

* **Maximizes Resilience**

  * Built-in health checks and self-healing mechanisms
  * Easy backup and restore of workflow data and credentials
  * Rolling updates to avoid downtime

* **Fortifies Security**

  * Traefik reverse proxy with HTTP/2 & TLS 1.3
  * HTTP basic authentication and IP-whitelisting options
  * Automatic security patching for underlying OS components

Whether you’re running mission-critical automations or experimenting with new workflows, this script takes care of the heavy lifting—so you can focus on building what matters. Get up and running in minutes, with deployment best practices baked in.
