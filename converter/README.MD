## base64_brases.sh
batch conversion [vmess://(Base64 encoded json format server data) ](https://github.com/2dust/v2rayN/wiki/%E5%88%86%E4%BA%AB%E9%93%BE%E6%8E%A5%E6%A0%BC%E5%BC%8F%E8%AF%B4%E6%98%8E(ver-2)#%E5%88%86%E4%BA%AB%E7%9A%84%E9%93%BE%E6%8E%A5%E4%BA%8C%E7%BB%B4%E7%A0%81%E6%A0%BC%E5%BC%8Fvmessbase64%E7%BC%96%E7%A0%81%E7%9A%84json%E6%A0%BC%E5%BC%8F%E6%9C%8D%E5%8A%A1%E5%99%A8%E6%95%B0%E6%8D%AE).


```
Usage: ./base64_braces.sh [-e|--encode] [-d|--decode] input_file [delimiter] [-h|--help]
Options:
  -e, --encode      Encode the input file contents using base64
  -d, --decode      Decode the input file contents from base64
  input_file        The input file to be processed
  delimiter         The delimiter for separating content blocks in input file
                    Options: ; , {} | @
  -h, --help        Display this help message
```
The name of the output file is input_file.encoded.

```bash
./base64_braces.sh -e test1
```

## example: 
The name of the input file is test1, the content format:
```
{
        "v": "2",
        "ps": " 备注或别名  ",
        "add": "111.111.111.111",
        "port": "32000",
        "id": "1386f85e-657b-4d6e-9d56-78badb75e1fd",
        "aid": "100",
        "scy": "zero",
        "net": "tcp",
        "type": "none",
        "host": "www.bbb.com",
        "path": "/",
        "tls": "tls",
        "sni": "www.ccc.com",
        "alpn": "h2",
        "fp": "chrome"
}
{
        "v": "2",
        "ps": " 备注或别",
        "add": "111.111.111.112",
        "port": "32000",
        "id": "1386f85e-657b-4d6e-9d56-78badb75e1fd",
        "aid": "100",
        "scy": "zero",
        "net": "tcp",
        "type": "none",
        "host": "www.bbb.com",
        "path": "/",
        "tls": "tls",
        "sni": "www.ccc.com",
        "alpn": "h2",
        "fp": "chrome"
}
```

The name of the output file is test1.encoded, the content format:
```
vmess://ewoJInYiOiAiMiIsCgkicHMiOiAiIOWkh+azqOaIluWIq+WQjSAgIiwKCSJhZGQiOiAiMTExLjExMS4xMTEuMTExIiwKCSJwb3J0IjogIjMyMDAwIiwKCSJpZCI6ICIxMzg2Zjg1ZS02NTdiLTRkNmUtOWQ1Ni03OGJhZGI3NWUxZmQiLAoJImFpZCI6ICIxMDAiLAoJInNjeSI6ICJ6ZXJvIiwKCSJuZXQiOiAidGNwIiwKCSJ0eXBlIjogIm5vbmUiLAoJImhvc3QiOiAid3d3LmJiYi5jb20iLAoJInBhdGgiOiAiLyIsCgkidGxzIjogInRscyIsCgkic25pIjogInd3dy5jY2MuY29tIiwKCSJhbHBuIjogImgyIiwKCSJmcCI6ICJjaHJvbWUiCn0=
vmess://CnsKCSJ2IjogIjIiLAoJInBzIjogIiDlpIfms6jmiJbliKsiLAoJImFkZCI6ICIxMTEuMTExLjExMS4xMTIiLAoJInBvcnQiOiAiMzIwMDAiLAoJImlkIjogIjEzODZmODVlLTY1N2ItNGQ2ZS05ZDU2LTc4YmFkYjc1ZTFmZCIsCgkiYWlkIjogIjEwMCIsCgkic2N5IjogInplcm8iLAoJIm5ldCI6ICJ0Y3AiLAoJInR5cGUiOiAibm9uZSIsCgkiaG9zdCI6ICJ3d3cuYmJiLmNvbSIsCgkicGF0aCI6ICIvIiwKCSJ0bHMiOiAidGxzIiwKCSJzbmkiOiAid3d3LmNjYy5jb20iLAoJImFscG4iOiAiaDIiLAoJImZwIjogImNocm9tZSIKfQ==
```