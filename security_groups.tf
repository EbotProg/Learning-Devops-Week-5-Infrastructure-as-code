resource "aws_security_group" "bastion" {
  name        = "Bastion SG"
  description = "Allows ssh from only my ip address"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = "${var.bastion_allowed_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "bastion_out" {
  security_group_id = aws_security_group.bastion.id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "app_tier" {
  name        = "App-tier SG"
  description = "Allows ssh only from bastion"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "app_tier_ssh_from_bastion" {
  security_group_id            = aws_security_group.app_tier.id
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

# NOTE: this egress rule was missing from the original guide skeleton.
# Terraform-created security groups have NO default outbound allow-all
# (unlike a console-created one) — without this, the app-tier instance
# can't reach the internet via NAT at all (no apt-get, no docker pull, etc).
resource "aws_vpc_security_group_egress_rule" "app_tier_out" {
  security_group_id = aws_security_group.app_tier.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
