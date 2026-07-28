package main; import "core:encoding/base64"; import "core:fmt"; main :: proc() { fmt.println(type_of(base64.decode)); }
