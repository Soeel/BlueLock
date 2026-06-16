{{ with secret "pki/issue/bastion-role" "common_name=bastion.blue.local" "ttl=720h" }}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{ end }}