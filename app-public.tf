# A separate public-subnet instance for the actual Month 1 CRUD app.
# The private "app" instance (ec2.tf) stays as the Week 2 bastion-pattern
# demonstration — this is a distinct resource because that instance has no
# internet-facing route at all, so it can never serve a browser request.

resource "aws_security_group" "app_public" {
  name        = "App-public SG"
  description = "Direct access to the CRUD app ports, from my IP only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "app_public_ssh" {
  security_group_id = aws_security_group.app_public.id
  cidr_ipv4         = "${var.bastion_allowed_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# frontend, backend, dashboard — matching your Week 3 docker-compose.yml ports
resource "aws_vpc_security_group_ingress_rule" "app_public_frontend" {
  security_group_id = aws_security_group.app_public.id
  cidr_ipv4         = "${var.bastion_allowed_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 3003
  to_port           = 3003
}

resource "aws_vpc_security_group_ingress_rule" "app_public_backend" {
  security_group_id = aws_security_group.app_public.id
  cidr_ipv4         = "${var.bastion_allowed_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 1338
  to_port           = 1338
}

resource "aws_vpc_security_group_ingress_rule" "app_public_dashboard" {
  security_group_id = aws_security_group.app_public.id
  cidr_ipv4         = "${var.bastion_allowed_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 4041
  to_port           = 4041
}

resource "aws_vpc_security_group_egress_rule" "app_public_out" {
  security_group_id = aws_security_group.app_public.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "app_public" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public1.id
  vpc_security_group_ids = [aws_security_group.app_public.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_repository_profile.name

  root_block_device {
    volume_size = 20 # default 8GB is not enough for 4 images + Docker layers + apt packages
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    account_id = data.aws_caller_identity.current.account_id
  })

  tags = { Name = "app-public-crud" }
}
