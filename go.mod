module github.com/anywaye/keyholder

// The same toolchain number `gateway/go.mod`, `identity/go.mod` and
// `pantry/go.mod` already state. Nothing makes the go command read a version
// manager's config, so a toolchain pin that lives only there is a comment.
go 1.26.1

require github.com/golang-jwt/jwt/v5 v5.3.1
