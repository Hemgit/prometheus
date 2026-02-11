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
        "nginx"
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

              location /alertmanager/ {
                proxy_pass http://localhost:9093/;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
              }

              location /metrics/ {
                proxy_pass http://localhost:9100/;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
              }
            }
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


