`timescale 1ns/1ps

package l1d_cache_pkg;
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_LOOKUP,
        ST_HIT_WRITE,
        ST_VC_SWAP,
        ST_WB_REQ,
        ST_VC_INSERT,
        ST_MEM_READ_REQ,
        ST_MEM_READ_WAIT,
        ST_INSTALL,
        ST_RESP
    } state_t;
endpackage
