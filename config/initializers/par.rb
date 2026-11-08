# uint256 values are bound into numeric(78,0) columns; Rails' guard against >64-bit integer binds
# exists for bigint columns and does not apply here.
ActiveRecord.raise_int_wider_than_64bit = false
