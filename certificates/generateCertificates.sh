domainName="mycustomdomain.com"

#Create the Root private key. Remove -des3 to create passwordless private key
openssl genrsa -des3 -out rootCA.key 4096

#Create and self sign the Root Certificate
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 1024 -out rootCA.crt

openssl x509 -export 
#Create the server certificate keys
openssl genrsa -out $domainName.key 2048

#Make sure that .rnd file is available
touch .rnd

#Create the certificate signing requests
openssl req -new -sha256 -key apidemo.com.key -subj /CN=*.apidemo.com -out apidemo.com.csr 

#Create the V3 file
cat > v3.ext <<EOF
    authorityKeyIdentifier=keyid,issuer
    basicConstraints=CA:FALSE
    keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
    subjectAltName = @alt_names
    [alt_names]
    DNS.1 = *.apidemo.com
EOF

#Generate the certificates using the mydomain csr and key along with the CA Root key
openssl x509 -req -in apidemo.com.csr -CA rootCA.crt -CAkey rootCA.key -CAcreateserial -out apidemo.com.crt -days 730 -sha256 -extfile v3.ext


#Genere pfx file for the certificates
openssl pkcs12 -export -out apidemo.com.pfx -inkey apidemo.com.key -in apidemo.com.crt
