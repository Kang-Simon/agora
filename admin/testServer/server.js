const http = require("http");
const url = require("url");
const crypto = require("crypto");
const server = http.createServer(function (req, res) {
  console.log(req.url);
  let parsedUrl = url.parse(req.url);
  let resource = parsedUrl.pathname;
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Request-Method", "*");
  res.setHeader("Access-Control-Allow-Methods", "OPTIONS, GET");
  res.setHeader("Access-Control-Allow-Headers", "*");
  if (resource === "/login") {
    res.setHeader("Content-Type", "application/json");
    res.end(
      JSON.stringify({
        status: 0,
        data: "md+31zMRMVqPgR9b99kSCEWZdIIdFUREO38ok6oFX50=",
      })
    );
  } else if (resource === "/admin/validator") {
    res.setHeader("Content-Type", "application/json");
    res.end(
      JSON.stringify({
        private_key: "SBFLURYJRXVJDQRQSTSGDEKI6HDQE4R6QKYJXNULFXX4PEHVIJCAQ3IV",
        voter_card: {
          validator: crypto.randomBytes(64).toString("hex"),
          address: "boa1" + crypto.randomBytes(64).toString("hex"),
          expires: "2021-11-03T02:08:14Z",
          signature: crypto.randomBytes(128).toString("hex"),
        },
      })
    );
  } else if (resource === "/admin/encryptionkey") {
    res.setHeader("Content-Type", "application/json");
    res.end(
      JSON.stringify({
        private_key: "encryption key TEST DATA",
        voter_card: {
          validator: "ADMIN VALIDATOR",
          address: "boa1" + crypto.randomBytes(64).toString("hex"),
          expires: "2021-11-03T02:08:14Z",
          signature: "0x"+crypto.randomBytes(128).toString("hex"),
        },
      })
    );
  } else {
    res.writeHead(404, { "Content-Type": "text/html" });
    res.end("404 Page Not Found");
  }
});
server.listen(4040);
