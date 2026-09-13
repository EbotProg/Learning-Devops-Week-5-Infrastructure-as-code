resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public1.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = var.key_name

  tags = { Name = "bastion" }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private1.id
  vpc_security_group_ids = [aws_security_group.app_tier.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_repository_profile.name

  tags = { Name = "app-tier" }
}
