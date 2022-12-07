provider "aws" {
    region="us-east-2"
}
resource "aws_launch_configuration" "example" {
    image_id            = "ami-0fb653ca2d3203ac1"
    instance_type       = "t2.micro"
    security_groups     = [aws_security_group.instance.id]

    user_data = <<-EOF
                #!/bin/bash
                echo "Hello, World" > index.html
                nohup busybox httpd -f -p ${var.server_port} &
                EOF


     # Required when using a launch configuration with an auto scaling group.
     lifecycle {
        create_before_destroy = true
     }       
}

resource "aws_security_group" "instance" {
    name = "terraform-example-instance"

    ingress {
        from_port = var.server_port
        to_port = var.server_port
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

variable "server_port" {
    description = "The port the server will use for HTTP requests"
    type = number
    default = 8080
}

resource "aws_autoscaling_group" "example" {
    launch_configuration    = aws_launch_configuration.example.name
    
    # Pull the subnets IDs out of aws_subnets data source and tell your ASG to use those subnets
    vpc_zone_identifier     = data.aws_subnets.default.ids

    target_group_arns   = [aws_lb_target_group.asg.arn]
    # Update health_check_type to "ELB", default is "EC2"
    health_check_type        = "ELB"

    min_size = 2
    max_size = 10

    tag {
        key                 = "Name"
        value               = "terraform-asg-example"
        propagate_at_launch = true
    }
}

# Lookup Default VPC in your AWS account
data "aws_vpc" "default" {
    default = true
}

# Lookup the subnets within Default VPC
data "aws_subnets" "default" {
    filter {
        name   = "vpc-id"
        values = [data.aws_vpc.default.id]
    }
}

# Create the ALB using the aws_lb resource
resource "aws_lb" "example" {
    name                = "terraform-asg-example"
    load_balancer_type  = "application"
    subnets             = data.aws_subnets.default.ids
    # Tell the ALB to use security group via security_groups argument
    security_groups     = [aws_security_group.alb.id]
}


# Define a listener for this ALB using the aws_lb_listener resource
resource "aws_lb_listener" "http" {
    load_balancer_arn   = aws_lb.example.arn
    port                = 80
    protocol            = "HTTP"

    # By default, return a simple 404 page
    default_action {
        type = "fixed-response"

        fixed_response {
            content_type    = "text/plain"
            message_body    = "404: page not found"
            status_code     = 404
        }
    }

}

# Create a security group for ALB
resource "aws_security_group" "alb" {
    name = "terraform-example-alb"

    # Allow inbound HTTP requests
    ingress {
        from_port       = 80
        to_port         = 80
        protocol        = "tcp"
        cidr_blocks     = ["0.0.0.0/0"]
    }

    # Allow all outbound requests
    egress {
        from_port       = 0
        to_port         = 0
        protocol        = "-1"
        cidr_blocks     = ["0.0.0.0/0"]
    }
}

# Create a target group for your ASG using the aws_lb_target_group resource
resource "aws_lb_target_group" "asg" {
    name        = "terraform-asg-example"
    port        = var.server_port
    protocol    = "HTTP"
    vpc_id      = data.aws_vpc.default.id

    health_check {
        path                = "/"
        protocol            = "HTTP"
        matcher             = "200"
        interval            = 15
        timeout             = 3
        healthy_threshold   = 2
        unhealthy_threshold = 2
    }

}

# Tie all the pieces together by creating listener rules
resource "aws_lb_listener_rule" "asg" {
    listener_arn    = aws_lb_listener.http.arn
    priority        = 100

    condition {
        path_pattern {
            values = ["*"]
        }
    }

    action {
        type                = "forward"
        target_group_arn    = aws_lb_target_group.asg.arn
    }
}

output "alb_dns_name" {
    value       = aws_lb.example.dns_name
    description = "The domain name of the load balancer"
}

