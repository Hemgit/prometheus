terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>3.0"
    }
  }
}

provider "aws" {
  region = "eu-north-1"
}

resource "aws_security_group" "grafana_sg" {
  name        = "grafana_sg"
  description = "security group for grafana server"

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
    Name = "grafana_sg"
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

data "cloudinit_config" "grafana" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = yamlencode({
      package_update  = true
      package_upgrade = true

      write_files = [
        {
          path = "/etc/apt/sources.list.d/grafana.list"
          content = "deb https://packages.grafana.com/oss/deb stable main"
        },
        {
          path = "/etc/grafana/grafana.ini"
          content = <<-EOT
            [server]
            http_port = 3000
            domain = localhost
            root_url = http://localhost:3000
            
            [security]
            admin_user = admin
            admin_password = admin
            
            [users]
            allow_sign_up = false
          EOT
        },
        {
          path = "/etc/nginx/sites-available/grafana"
          content = <<-EOT
            server {
              listen 80;
              server_name _;

              location / {
                proxy_pass http://localhost:3000/;
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
        "apt-get install -y adduser libfontconfig1 wget nginx",
        "wget https://dl.grafana.com/oss/release/grafana_9.3.2_amd64.deb",
        "sudo dpkg -i grafana_9.3.2_amd64.deb",
        "systemctl daemon-reload",
        "systemctl enable grafana-server",
        "systemctl start grafana-server",
        "ln -s /etc/nginx/sites-available/grafana /etc/nginx/sites-enabled/",
        "rm -f /etc/nginx/sites-enabled/default",
        "nginx -t && systemctl restart nginx",
        "systemctl enable nginx"
      ]
    })
  }
}

resource "aws_instance" "grafana_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.grafana_sg.id]
  key_name               = "test1"
  user_data              = data.cloudinit_config.grafana.rendered

  tags = {
    Name = "grafana_server"
  }
}

output "grafana_public_ip" {
  value       = aws_instance.grafana_server.public_ip
  description = "Public IP of Grafana server"
}

output "grafana_url" {
  value       = "http://${aws_instance.grafana_server.public_ip}"
  description = "Grafana URL (default credentials: admin/admin)"
}
