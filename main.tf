terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>3.0"
    }
  }
}
provider "aws" { region = "eu-north-1" }

resource "aws_security_group" "prometheus_sg" {
  name        = "prometheus_sg"
  description = "security group for prometheus server"
  dynamic "ingress" {
    iterator = port
    for_each = var.ports
    content {
      from_port   = port.value
      to_port     = port.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow traffic"
  }

}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

data "cloudinit_config" "monitoring" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = yamlencode({
      packages = [
        "prometheus",
        "prometheus-node-exporter",
        "prometheus-alertmanager",
        "nginx",
        "wget"
      ]
      package_update  = true
      package_upgrade = true

      write_files = [
        {
          path = "/etc/nginx/sites-available/monitoring"
          content = <<-EOT
            server {
              listen 80;
              server_name _;

              location / {
                proxy_pass http://localhost:9090/;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
              }

              location /prometheus/metrics {
                proxy_pass http://localhost:9090/metrics;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
              }

              location /node/metrics {
                proxy_pass http://localhost:9100/metrics;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
              }
              location /alm/ {
                proxy_pass http://localhost:9093/;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
              }

              location /blackbox/ {
                proxy_pass http://localhost:9115/;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
              }
            }
          EOT
        },
        {
          path = "/etc/prometheus/rules.yml"
          content = <<-EOT
            groups:
              - name: alert_rules
                rules:
                  - alert: InstanceDown
                    expr: up == 0
                    for: 1m
                    labels:
                      severity: critical
                    annotations:
                      summary: 'Instance {{ $labels.instance }} down'
                      description: '{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 1 minute.'
          EOT
        },
        {
          path = "/etc/prometheus/blackbox.yml"
          content = <<-EOT
            modules:
              http_2xx:
                prober: http
                timeout: 5s
                http:
                  valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
                  valid_status_codes: []
                  method: GET
                  preferred_ip_protocol: "ip4"
              http_post_2xx:
                prober: http
                timeout: 5s
                http:
                  method: POST
              tcp_connect:
                prober: tcp
                timeout: 5s
              icmp:
                prober: icmp
                timeout: 5s
          EOT
        }
      ]

      runcmd = [
        "systemctl enable prometheus",
        "systemctl start prometheus",
        "systemctl enable prometheus-node-exporter",
        "systemctl start prometheus-node-exporter",
        "systemctl enable prometheus-alertmanager",
        "systemctl start prometheus-alertmanager",
        "cd /opt && wget https://github.com/prometheus/blackbox_exporter/releases/download/v0.24.0/blackbox_exporter-0.24.0.linux-amd64.tar.gz",
        "tar xzf /opt/blackbox_exporter-0.24.0.linux-amd64.tar.gz -C /opt/",
        "mv /opt/blackbox_exporter-0.24.0.linux-amd64 /opt/blackbox_exporter",
        "useradd --no-create-home --shell /bin/false prometheus-blackbox || true",
        "chown -R prometheus-blackbox:prometheus-blackbox /opt/blackbox_exporter",
        "cp /opt/blackbox_exporter/blackbox.yml /etc/prometheus/ || true",
        "chown prometheus-blackbox:prometheus-blackbox /etc/prometheus/blackbox.yml",
        "echo '[Unit]",
        "Description=Prometheus Blackbox Exporter",
        "After=network.target",
        "",
        "[Service]",
        "Type=simple",
        "User=prometheus-blackbox",
        "Group=prometheus-blackbox",
        "ExecStart=/opt/blackbox_exporter/blackbox_exporter --config.file=/etc/prometheus/blackbox.yml",
        "Restart=always",
        "RestartSec=5",
        "",
        "[Install]",
        "WantedBy=multi-user.target' > /etc/systemd/system/prometheus-blackbox-exporter.service",
        "systemctl daemon-reload",
        "systemctl enable prometheus-blackbox-exporter",
        "systemctl start prometheus-blackbox-exporter",
        "ln -s /etc/nginx/sites-available/monitoring /etc/nginx/sites-enabled/",
        "rm -f /etc/nginx/sites-enabled/default",
        "nginx -t && systemctl restart nginx",
        "systemctl enable nginx"
      ]
    })
  }
}

resource "aws_instance" "prometheus_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.prometheus_sg.id]
  key_name               = "test1"
  user_data              = data.cloudinit_config.monitoring.rendered

  tags = {
    Name = "prometheus_server"
  }
}


