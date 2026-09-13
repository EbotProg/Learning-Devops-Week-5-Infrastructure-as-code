output "bastion_public_ip" {
  value       = aws_instance.bastion.public_ip
  description = "ssh -i <your-key>.pem ubuntu@<this-ip>"
}

output "app_private_ip" {
  value       = aws_instance.app.private_ip
  description = "From the bastion: ssh ubuntu@<this-ip>"
}

output "s3_website_endpoint" {
  value       = aws_s3_bucket_website_configuration.milestone.website_endpoint
  description = "Upload an index.html here and open this URL in a browser to verify reachability"
}

output "app_public_ip" {
  value       = aws_instance.app_public.public_ip
  description = "The actual CRUD app — give the user_data script 2-3 minutes after apply before checking"
}

output "app_urls" {
  value = {
    frontend  = "http://${aws_instance.app_public.public_ip}:3003"
    backend   = "http://${aws_instance.app_public.public_ip}:1338/parse/health"
    dashboard = "http://${aws_instance.app_public.public_ip}:4041"
  }
}
