lib: networks: "${lib.concatMapStrings (n: "allow ${n};\n") networks}deny all;"
