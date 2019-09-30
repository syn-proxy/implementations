/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_IPV4 = 0x800;
const bit<8>  TCP_PROTOCOL = 0x06;
const bit<8>  UDP_PROTOCOL = 0x11;   // UDP parsing is not implemented


#define BLOOM_FILTER_ENTRIES 4096
#define BLOOM_FILTER_BIT_WIDTH 1

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header tcp_t{
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<4>  res;
    bit<1>  cwr;
    bit<1>  ece;
    bit<1>  urg;
    bit<1>  ack;
    bit<1>  psh;
    bit<1>  rst;
    bit<1>  syn;
    bit<1>  fin;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

struct metadata {
    bit<32> register_position_one;
    bit<32> register_position_two;
    bit<1> register_cell_one;
    bit<1> register_cell_two;

    bit<16> tcpLength; // this value is computed for each packet for TCP checksum recalculations
}

struct headers {
    ethernet_t   ethernet;
    ipv4_t       ipv4;
    tcp_t      tcp;
}


/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            TCP_PROTOCOL: parse_tcp;
            default: accept;
        }
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }

}

/*************************************************************************
************   C H E C K S U M    V E R I F I C A T I O N   *************
*************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {
       verify_checksum(
	    hdr.ipv4.isValid(),
            { hdr.ipv4.version,
	      hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr},
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
      }
}


/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    register<bit<BLOOM_FILTER_BIT_WIDTH>>(BLOOM_FILTER_ENTRIES) bloom_filter;
    action drop() {
        mark_to_drop();
    }

    action set_allowed(){
       //Get register position
       // use for the hash all information about the connection except client port number because the client can use different ports
       //for white list hash I think the addresses are enough, but adding extra information about the connection is always good
       hash(meta.register_position_one, HashAlgorithm.crc16, (bit<32>)0, {hdr.ipv4.srcAddr,
                                                          hdr.ipv4.dstAddr,
                                                          hdr.tcp.dstPort,
                                                          hdr.ipv4.protocol},
                                                          (bit<32>)BLOOM_FILTER_ENTRIES);

       hash(meta.register_position_two, HashAlgorithm.crc32, (bit<32>)0, {hdr.ipv4.srcAddr,
                                                          hdr.ipv4.dstAddr,
                                                          hdr.tcp.dstPort,
                                                          hdr.ipv4.protocol},
                                                          (bit<32>)BLOOM_FILTER_ENTRIES);

        //set bloom filter fields
        bloom_filter.write(meta.register_position_one, 1);
        bloom_filter.write(meta.register_position_two, 1);
    }

    action check_if_allowed(){

        hash(meta.register_position_one, HashAlgorithm.crc16, (bit<32>)0, {hdr.ipv4.srcAddr,
                                                          hdr.ipv4.dstAddr,
                                                          hdr.tcp.dstPort,
                                                          hdr.ipv4.protocol},
                                                          (bit<32>)BLOOM_FILTER_ENTRIES);

        hash(meta.register_position_two, HashAlgorithm.crc32, (bit<32>)0, {hdr.ipv4.srcAddr,
                                                          hdr.ipv4.dstAddr,
                                                          hdr.tcp.dstPort,
                                                          hdr.ipv4.protocol},
                                                          (bit<32>)BLOOM_FILTER_ENTRIES);

        //Read bloom filter cells to check if there are 1's
        bloom_filter.read(meta.register_cell_one, meta.register_position_one);
        bloom_filter.read(meta.register_cell_two, meta.register_position_two);
    }

    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    action reset_connection(){
        //Set RST flag and bounce packet back out on the same port it came into
        hdr.tcp.rst = 1;
        hdr.tcp.syn = 0;
        hdr.tcp.ack = 0;

        //Set the correct IP addresses, RESET from SERVER to CLIENT

        bit<32> clientAddr = hdr.ipv4.srcAddr;
        bit<32> serverAddr = hdr.ipv4.dstAddr;

        hdr.ipv4.srcAddr = serverAddr;
        hdr.ipv4.dstAddr = clientAddr;

        //Switch port numbers as well
        bit<16> clientPort = hdr.tcp.srcPort;
        bit<16> serverPort = hdr.tcp.dstPort;
        hdr.tcp.dstPort = clientPort;
        hdr.tcp.srcPort = serverPort;
    }

    // for TCP checksum calculations, TCP checksum requires some IPv4 header fields in addition to TCP checksum that is
    //not present as a value and must be computed, tcp length = length in bytes of TCP header + TCP payload
    // from IPv4 header we have ipv4 total length that is a sum of the ip header and the ip payload (in our case) the TCP length
    // IPv4 length is IHL field * 4 bytes (or 32 bits 8*4), therefore, tcp length = ipv4 total length - ipv4 header length
    action compute_tcp_length(){
        bit<16> tcpLength;
        bit<16> ipv4HeaderLength = ((bit<16>) hdr.ipv4.ihl) * 4;
        //this gives the size of IPv4 header in bytes, since ihl value represents
        //the number of 32-bit words including the options field
        tcpLength = hdr.ipv4.totalLen - ipv4HeaderLength;
        // save this value to metadata to be used later in checksum computation
        meta.tcpLength = tcpLength;
    }


    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }


    apply {
        // if the packet is establishing a TCP connection with SYN flag set, check white list
        if(hdr.tcp.isValid() && hdr.tcp.syn == 1){
           check_if_allowed();
           // if the connection is new , reset the connection and add to whitelist
           if (meta.register_cell_one != 1 || meta.register_cell_two != 1){
               set_allowed();
               reset_connection();
           }
        }
        // Normal forwarding scenario
        if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();
        }
       // TCP length is required for TCP header checksum value calculations.
       compute_tcp_length();

    }
}
/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    apply {  }
}

/*************************************************************************
*************   C H E C K S U M    C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers  hdr, inout metadata meta) {
     apply {
	update_checksum(
	    hdr.ipv4.isValid(),
            { hdr.ipv4.version,
	      hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);

      update_checksum_with_payload(
	    hdr.tcp.isValid() && hdr.ipv4.isValid(),
            { hdr.ipv4.srcAddr,
	      hdr.ipv4.dstAddr,
              8w0,
              hdr.ipv4.protocol,
              meta.tcpLength,
              hdr.tcp.srcPort,
              hdr.tcp.dstPort,
              hdr.tcp.seqNo,
              hdr.tcp.ackNo,
              hdr.tcp.dataOffset,
              hdr.tcp.res,
              hdr.tcp.cwr,
              hdr.tcp.ece,
              hdr.tcp.urg,
              hdr.tcp.ack,
              hdr.tcp.psh,
              hdr.tcp.rst,
              hdr.tcp.syn,
              hdr.tcp.fin,
              hdr.tcp.window,
              hdr.tcp.urgentPtr
              },
            hdr.tcp.checksum,
            HashAlgorithm.csum16);

    }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
