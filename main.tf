terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.0.0"
    }
  }
}
provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = "true"
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  
  // This is the ID of the publisher that created the AMI. 
  // The publisher of Ubuntu 20.04 LTS Focal is Canonical 
  // and their ID is 099720109477
  owners = ["099720109477"]
}

resource "aws_vpc" "app_vpc" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = true

  tags = {
    Name = "app_vpc"
  }
}

resource "aws_internet_gateway" "app_igw" {
  vpc_id = aws_vpc.app_vpc.id
  tags = {
    Name = "app_igw"
  }
}

resource "aws_subnet" "app_public_subnet" {
  count             = var.subnet_count.public
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = var.public_subnet_cidr_blocks[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "app_public_subnet_${count.index}"
  }
}

resource "aws_subnet" "app_private_subnet" {
  count             = var.subnet_count.private
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = var.private_subnet_cidr_blocks[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "app_private_subnet_${count.index}"
  }
}

resource "aws_route_table" "app_public_rt" {
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app_igw.id
  }
}


resource "aws_route_table_association" "public" {
   count          = var.subnet_count.public
  route_table_id = aws_route_table.app_public_rt.id
  subnet_id      = 	aws_subnet.app_public_subnet[count.index].id
}

resource "aws_route_table" "app_private_rt" {
  vpc_id = aws_vpc.app_vpc.id
}


resource "aws_route_table_association" "private" {
  count          = var.subnet_count.private
  route_table_id = aws_route_table.app_private_rt.id
  subnet_id      = aws_subnet.app_private_subnet[count.index].id
}


resource "aws_security_group" "app_web_sg" {
  name        = "app_web_sg"
  description = "Security group web servers"
  vpc_id      = aws_vpc.app_vpc.id


  ingress {
    description = "Allow all traffic through HTTP"
    from_port   = "80"
    to_port     = "80"
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow all traffic through HTTPS"
    from_port   = "443"
    to_port     = "443"
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH from my pc"
    from_port   = "22"
    to_port     = "22"
    protocol    = "tcp"
    // only allow connection to allowed admin ip
    cidr_blocks = ["${var.my_allowed_ip}/32"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "app_web_sg"
  }
}

resource "aws_security_group" "app_db_sg" {
  name        = "app_db_sg"
  description = "Security group for the app database"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    description     = "Allow Postgres traffic from only the web sg"
    from_port       = "5432"
    to_port         = "5432"
    protocol        = "tcp"
    security_groups = [aws_security_group.app_web_sg.id]
  }

  tags = {
    Name = "app_db_sg"
  }
}

resource "aws_db_subnet_group" "app_db_subnet_group" {
  name        = "app_db_subnet_group"
  description = "DB subnet group for app"
  subnet_ids  = [for subnet in aws_subnet.app_private_subnet : subnet.id]
}

resource "aws_db_instance" "app_database" {
  allocated_storage      = var.settings.database.allocated_storage
  engine                 = var.settings.database.engine
  engine_version         = var.settings.database.engine_version
  instance_class         = var.settings.database.instance_class
  db_name                = var.settings.database.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.app_db_subnet_group.id
  vpc_security_group_ids = [aws_security_group.app_db_sg.id]
  skip_final_snapshot    = var.settings.database.skip_final_snapshot
}

resource "aws_key_pair" "app_kp" {
  key_name   = "app_kp"
  public_key = file("app_kp.pub")
}

resource "aws_instance" "app_web" {
  count                  = var.settings.web_server.count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.settings.web_server.instance_type
  subnet_id              = aws_subnet.app_public_subnet[count.index].id
  key_name               = aws_key_pair.app_kp.key_name
  vpc_security_group_ids = [aws_security_group.app_web_sg.id]
  
  ebs_block_device {
    device_name = "/dev/sda1"
    volume_size = 200
  }


  tags = {
    Name = "app_web_${count.index}"
  }
}


resource "aws_eip" "app_web_eip" {
  count    = var.settings.web_server.count
  instance = aws_instance.app_web[count.index].id
  vpc      = true


  tags = {
    Name = "app_web_eip_${count.index}"
  }
}
