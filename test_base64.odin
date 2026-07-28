package main
import "core:fmt"
import "core:encoding/base64"

main :: proc() {
    res := base64.decode("YWJj")
    fmt.println(res)
}
