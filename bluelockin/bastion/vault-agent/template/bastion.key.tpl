{{ with secret "pki/issue/bastion-role" "common_name=bastion.blue.local" "ttl=720h" }}
{{ .Data.private_key }}
{{ end }}