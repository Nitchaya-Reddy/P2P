// Chord: A Scalable Peer-to-peer Lookup Service for Internet Applications
// Implementation based on: Stoica et al., ACM SIGCOMM 2001
// Paper: https://pdos.csail.mit.edu/papers/ton:chord/paper-ton.pdf
//
// SHA-1 hash function implementation following RFC 3174 specification
// Reference: https://tools.ietf.org/html/rfc3174

import gleam/io
import gleam/int
import gleam/float
import gleam/list
import gleam/result
import gleam/string
import gleam/erlang/process.{type Subject}
import gleam/erlang/charlist
import gleam/otp/actor
import gleam/dict.{type Dict}
import gleam/bit_array

@external(erlang, "init", "get_plain_arguments")
fn get_plain_arguments() -> List(charlist.Charlist)

const chord_m = 16
const ring_size = 65536
pub type NodeId = Int

// SHA-1 implementation (RFC 3174)
// SHA-1 produces 160-bit hash, we use modulo to fit in Chord ring

fn generate_node_id(node_string: String) -> NodeId {
  // strong_hash(node_string)
  let hash_bytes = sha1_hash(node_string)
  let hash_int = bytes_to_int(hash_bytes)
  hash_int % ring_size

}

fn generate_key_hash(key: String) -> NodeId {
  let hash_bytes = sha1_hash(key)
  let hash_int = bytes_to_int(hash_bytes)
  hash_int % ring_size
}

// Convert first 4 bytes to integer for Chord ID
fn bytes_to_int(bytes: BitArray) -> Int {
  case bit_array.slice(bytes, 0, 4) {
    Ok(slice) -> {
      case bit_array.to_string(slice) {
        Ok(s) -> {
          string.to_utf_codepoints(s)
          |> list.fold(0, fn(acc, cp) { acc * 256 + string.utf_codepoint_to_int(cp) })
        }
        Error(_) -> 0
      }
    }
    Error(_) -> 0
  }
}

// SHA-1 hash function (RFC 3174 specification)
fn sha1_hash(message: String) -> BitArray {
  // Initialize hash values (from RFC 3174 section 6.1)
  let h0 = 0x67452301
  let h1 = 0xEFCDAB89
  let h2 = 0x98BADCFE
  let h3 = 0x10325476
  let h4 = 0xC3D2E1F0
  
  let padded = sha1_pad_message(message)
  let chunks = sha1_create_chunks(padded, [])
  
  let #(final_h0, final_h1, final_h2, final_h3, final_h4) = 
    list.fold(chunks, #(h0, h1, h2, h3, h4), fn(h_values, chunk) {
      sha1_process_chunk(chunk, h_values)
    })
  
  // Convert hash values to bytes
  let result = <<
    final_h0:size(32),
    final_h1:size(32),
    final_h2:size(32),
    final_h3:size(32),
    final_h4:size(32)
  >>
  result
}

// Message padding (RFC 3174 section 4)
fn sha1_pad_message(message: String) -> BitArray {
  let msg_bits = bit_array.from_string(message)
  let msg_bit_length = bit_array.byte_size(msg_bits) * 8
  
  let padding_length = case { msg_bit_length + 8 } % 512 {
    n if n <= 448 -> 448 - n
    n -> 960 - n
  }
  
  let padding_bytes = padding_length / 8
  let zero_padding = bit_array.from_string(string.repeat("\u{0000}", padding_bytes))
  
  <<msg_bits:bits, 0x80:size(8), zero_padding:bits, msg_bit_length:size(64)>>
}

// Create 512-bit chunks (RFC 3174 section 6.1)
fn sha1_create_chunks(data: BitArray, acc: List(BitArray)) -> List(BitArray) {
  let byte_size = bit_array.byte_size(data)
  case byte_size >= 64 {
    True -> {
      case bit_array.slice(data, 0, 64) {
        Ok(chunk) -> {
          case bit_array.slice(data, 64, byte_size - 64) {
            Ok(rest) -> sha1_create_chunks(rest, [chunk, ..acc])
            Error(_) -> list.reverse(acc)
          }
        }
        Error(_) -> list.reverse(acc)
      }
    }
    False -> list.reverse(acc)
  }
}

// Process a single 512-bit chunk (RFC 3174 section 6.1)
fn sha1_process_chunk(chunk: BitArray, h_values: #(Int, Int, Int, Int, Int)) -> #(Int, Int, Int, Int, Int) {
  let #(h0, h1, h2, h3, h4) = h_values
  let words = sha1_create_words(chunk)
  let extended_words = extend_to_80_words(words)
  
  let #(a, b, c, d, e) = list.index_fold(
    list.range(0, 79),
    #(h0, h1, h2, h3, h4),
    fn(state, i, _idx) {
      let #(a_val, b_val, c_val, d_val, e_val) = state
      let #(f, k) = sha1_round_function(i, b_val, c_val, d_val)
      let w = get_word_at_index(extended_words, i)
      let temp = add32(add32(add32(add32(sha1_left_rotate(a_val, 5), f), e_val), k), w)
      #(temp, a_val, sha1_left_rotate(b_val, 30), c_val, d_val)
    }
  )
  
  #(add32(h0, a), add32(h1, b), add32(h2, c), add32(h3, d), add32(h4, e))
}

// Create 16 32-bit words from chunk
fn sha1_create_words(chunk: BitArray) -> List(Int) {
  sha1_bytes_to_words(chunk, 0, [])
}

fn sha1_bytes_to_words(data: BitArray, offset: Int, acc: List(Int)) -> List(Int) {
  case offset >= 64 {
    True -> list.reverse(acc)
    False -> {
      case bit_array.slice(data, offset, 4) {
        Ok(slice) -> {
          let word = case slice {
            <<w:size(32)>> -> w
            _ -> 0
          }
          sha1_bytes_to_words(data, offset + 4, [word, ..acc])
        }
        Error(_) -> list.reverse(acc)
      }
    }
  }
}

// Extend 16 words to 80 words (RFC 3174 section 6.1)
fn extend_to_80_words(words: List(Int)) -> List(Int) {
  let extended = list.fold(
    list.range(16, 79),
    words,
    fn(w_list, i) {
      let w_i_3 = get_word_at_index(w_list, i - 3)
      let w_i_8 = get_word_at_index(w_list, i - 8)
      let w_i_14 = get_word_at_index(w_list, i - 14)
      let w_i_16 = get_word_at_index(w_list, i - 16)
      let new_word = sha1_left_rotate(
        int.bitwise_exclusive_or(
          int.bitwise_exclusive_or(w_i_3, w_i_8),
          int.bitwise_exclusive_or(w_i_14, w_i_16)
        ),
        1
      )
      list.append(w_list, [new_word])
    }
  )
  extended
}

// SHA-1 round function (RFC 3174 section 5)
fn sha1_round_function(i: Int, b: Int, c: Int, d: Int) -> #(Int, Int) {
  case i {
    _ if i < 20 -> #(
      int.bitwise_or(int.bitwise_and(b, c), int.bitwise_and(int.bitwise_not(b), d)),
      0x5A827999
    )
    _ if i < 40 -> #(
      int.bitwise_exclusive_or(int.bitwise_exclusive_or(b, c), d),
      0x6ED9EBA1
    )
    _ if i < 60 -> #(
      int.bitwise_or(
        int.bitwise_or(int.bitwise_and(b, c), int.bitwise_and(b, d)),
        int.bitwise_and(c, d)
      ),
      0x8F1BBCDC
    )
    _ -> #(
      int.bitwise_exclusive_or(int.bitwise_exclusive_or(b, c), d),
      0xCA62C1D6
    )
  }
}

fn get_word_at_index(words: List(Int), index: Int) -> Int {
  case list.drop(words, index) {
    [word, ..] -> word
    [] -> 0
  }
}

// Left rotate for 32-bit integers
fn sha1_left_rotate(value: Int, bits: Int) -> Int {
  let masked = int.bitwise_and(value, 0xFFFFFFFF)
  let left = int.bitwise_shift_left(masked, bits)
  let right = int.bitwise_shift_right(masked, 32 - bits)
  int.bitwise_and(int.bitwise_or(left, right), 0xFFFFFFFF)
}

// 32-bit addition with overflow
fn add32(a: Int, b: Int) -> Int {
  int.bitwise_and(a + b, 0xFFFFFFFF)
}

pub type FingerEntry {
  FingerEntry(start: NodeId, successor: NodeId)
}

pub type ChordMessage {
  FindSuccessor(key: NodeId, from: Subject(ChordMessage), hops: Int)
  SuccessorFound(successor: NodeId, hops: Int)
  LookupValue(key: NodeId, from: Subject(ChordMessage), hops: Int)  
  ValueFound(key: NodeId, value: String, hops: Int)  
  SetupNode(successor: NodeId, fingers: List(FingerEntry), all_nodes: Dict(NodeId, Subject(ChordMessage)))
  StartBatch(keys: List(NodeId))
  ReportStats(coord: Subject(CoordinatorMessage))
  Stop
}

pub type CoordinatorMessage {
  StatsReceived(total_hops: Int, requests: Int)
  Complete
}

pub type ChordNode {
  ChordNode(
    id: NodeId,
    successor: NodeId,
    finger_table: List(FingerEntry),
    all_nodes: Dict(NodeId, Subject(ChordMessage)),
    hop_count: Int,
    request_count: Int,
    key_store: Dict(NodeId, String)  // Key-value pairs this node handles
  )
}

pub type Coordinator {
  Coordinator(expected_nodes: Int, total_requests: Int, responses: Int, collected_hops: Int)
}

pub fn main() {
  let args = get_plain_arguments() |> list.map(charlist.to_string)
  
  case args {
    [nodes_str, requests_str] -> {
      case int.parse(nodes_str), int.parse(requests_str) {
        Ok(num_nodes), Ok(num_requests) -> {
          let total_ops = num_nodes * num_requests
          case total_ops {
            ops if ops > 500000 -> {
              io.println("Error: Total operations (" <> int.to_string(ops) <> ") exceeds memory limit of 500,000")
            }
            _ -> case num_nodes > 0 && num_requests > 0 {
              True -> case num_nodes <= 5000 {
                True -> {
                  run_optimized_simulation(num_nodes, num_requests)
                }
                False -> io.println("Error: Maximum 5000 nodes supported")
              }
              False -> io.println("Error: Numbers must be positive")
            }
          }
        }
        _, _ -> io.println("Error: Invalid number format")
      }
    }
    _ -> io.println("Usage: gleam run -m project3_optimized <numNodes> <numRequests>")
  }
}

fn run_optimized_simulation(num_nodes: Int, num_requests: Int) {
  let node_ids = create_optimized_node_ids(num_nodes)
  let actual_node_count = list.length(node_ids) 
  case create_optimized_actors(node_ids) {
    Ok(node_actors) -> {
      let nodes_dict = create_nodes_dict(node_actors)
      setup_optimized_ring(node_actors, nodes_dict)
      case start_coordinator(actual_node_count, num_requests) {
        Ok(coordinator) -> {
          run_batched_simulation(node_actors, num_requests, actual_node_count)
          collect_results(node_actors, coordinator, actual_node_count)
        }
        Error(_) -> io.println("Error: Could not start coordinator")
      }
    }
    Error(msg) -> io.println("Error creating actors: " <> msg)
  }
}
fn create_optimized_node_ids(count: Int) -> List(NodeId) {
  let node_ids = list.range(0, count - 1) |> list.map(fn(i) {
    let node_string = "node_" <> int.to_string(i) <> "_" <> int.to_string(count)
    generate_node_id(node_string)
  })
  
  let unique_ids = list.unique(node_ids)
  let sorted_ids = list.sort(unique_ids, int.compare)
  
  sorted_ids
}

fn create_optimized_actors(node_ids: List(NodeId)) -> Result(List(#(NodeId, Subject(ChordMessage))), String) {
  let results = list.map(node_ids, create_single_actor)
  
  case list.all(results, fn(res) { 
    case res { 
      Ok(_) -> True 
      Error(_) -> False 
    }
  }) {
    True -> {
      let actors = list.fold(results, [], fn(acc, res) {
        case res {
          Ok(actor) -> [actor, ..acc]
          Error(_) -> acc
        }
      }) |> list.reverse
      Ok(actors)
    }
    False -> Error("Failed to create one or more actors")
  }
}

fn create_single_actor(node_id: NodeId) -> Result(#(NodeId, Subject(ChordMessage)), String) {
  let initial_store = dict.new() 
    |> dict.insert(node_id, "Value_" <> int.to_string(node_id))
    |> dict.insert(int.bitwise_and(node_id + 1, ring_size - 1), "Data_" <> int.to_string(node_id))
  
  let initial_state = ChordNode(
    id: node_id,
    successor: node_id,
    finger_table: [],
    all_nodes: dict.new(),
    hop_count: 0,
    request_count: 0,
    key_store: initial_store
  )
  
  case actor.new(initial_state)
       |> actor.on_message(handle_optimized_message)
       |> actor.start {
    Ok(started) -> Ok(#(node_id, started.data))
    Error(_) -> Error("Actor creation failed")
  }
}

fn create_nodes_dict(actors: List(#(NodeId, Subject(ChordMessage)))) -> Dict(NodeId, Subject(ChordMessage)) {
  list.fold(actors, dict.new(), fn(acc, pair) {
    dict.insert(acc, pair.0, pair.1)
  })
}

fn setup_optimized_ring(actors: List(#(NodeId, Subject(ChordMessage))), nodes_dict: Dict(NodeId, Subject(ChordMessage))) {
  let sorted_ids = list.map(actors, fn(pair) { pair.0 }) |> list.sort(int.compare)
  list.each(actors, fn(pair) {
    let node_id = pair.0
    let node_actor = pair.1
    let successor = find_successor(node_id, sorted_ids)
    let fingers = build_finger_table(node_id, sorted_ids)
    actor.send(node_actor, SetupNode(successor, fingers, nodes_dict))
  })
}

fn find_successor(id: NodeId, sorted_ids: List(NodeId)) -> NodeId {
  case list.find(sorted_ids, fn(node_id) { node_id > id }) {
    Ok(successor) -> successor
    Error(_) -> list.first(sorted_ids) |> result.unwrap(id)
  }
}

fn build_finger_table(node_id: NodeId, all_ids: List(NodeId)) -> List(FingerEntry) {
  list.range(0, chord_m - 1) |> list.map(fn(i) {
    let power = power_of_2(i)
    let start = int.bitwise_and(node_id + power, ring_size - 1)
    FingerEntry(start, find_successor(start, all_ids))
  })
}
fn power_of_2(exponent: Int) -> Int {
  case exponent {
    0 -> 1
    1 -> 2
    2 -> 4
    3 -> 8
    4 -> 16
    5 -> 32
    6 -> 64
    7 -> 128
    8 -> 256
    9 -> 512
    10 -> 1024
    11 -> 2048
    12 -> 4096
    13 -> 8192
    14 -> 16384
    15 -> 32768
    _ -> 65536 
  }
}

fn run_batched_simulation(actors: List(#(NodeId, Subject(ChordMessage))), num_requests: Int, num_nodes: Int) {
  case num_nodes > 500 {
    True -> {
      let batch_size = int.max(1, num_requests / 10)  // Process in chunks
      let num_batches = { num_requests + batch_size - 1 } / batch_size
      list.range(0, num_batches - 1) |> list.each(fn(batch_id) {
        list.each(actors, fn(pair) {
          let start_key = batch_id * batch_size + 1
          let end_key = int.min(start_key + batch_size - 1, num_requests)
          let keys = list.range(start_key, end_key) |> list.map(fn(i) {
            let key_string = "lookup_" <> int.to_string(pair.0) <> "_" <> int.to_string(i) <> "_batch_" <> int.to_string(batch_id)
            generate_key_hash(key_string)
          })
          actor.send(pair.1, StartBatch(keys))
        })
        process.sleep(50)  // Wait between batches
      })
    }
    False -> {
      list.each(actors, fn(pair) {
        let keys = list.range(1, num_requests) |> list.map(fn(i) {
          let key_string = "lookup_" <> int.to_string(pair.0) <> "_" <> int.to_string(i) <> "_direct"
          generate_key_hash(key_string)
        })
        actor.send(pair.1, StartBatch(keys))
      })
    }
  }
}
fn handle_optimized_message(state: ChordNode, message: ChordMessage) -> actor.Next(ChordNode, ChordMessage) {
  case message {
    SetupNode(succ, fingers, nodes) -> {
      let updated = ChordNode(..state, successor: succ, finger_table: fingers, all_nodes: nodes)
      actor.continue(updated)
    }
    FindSuccessor(key, from, hops) -> {
      case key == state.id || is_between(key, state.id, state.successor) {
        True -> {
          actor.send(from, SuccessorFound(state.successor, hops + 1))
          actor.continue(state)
        }
        False -> {
          let next_node = find_closest_finger(key, state)
          case dict.get(state.all_nodes, next_node) {
            Ok(next_actor) -> {
              actor.send(next_actor, FindSuccessor(key, from, hops + 1))
              actor.continue(state)
            }
            Error(_) -> {
              actor.send(from, SuccessorFound(state.successor, hops + 1))
              actor.continue(state)
            }
          }
        }
      }
    }
    LookupValue(key, from, hops) -> {
      case key == state.id || is_between(key, state.id, state.successor) {
        True -> {
          let value = dict.get(state.key_store, key) |> result.unwrap("Key_" <> int.to_string(key) <> "_NotFound")
          actor.send(from, ValueFound(key, value, hops + 1))
          actor.continue(state)
        }
        False -> {
          let next_node = find_closest_finger(key, state)
          case dict.get(state.all_nodes, next_node) {
            Ok(next_actor) -> {
              actor.send(next_actor, LookupValue(key, from, hops + 1))
              actor.continue(state)
            }
            Error(_) -> {
              actor.send(from, ValueFound(key, "Error_NodeNotReachable", hops + 1))
              actor.continue(state)
            }
          }
        }
      }
    }
    
    ValueFound(_key, _value, hops) -> {
      let updated = ChordNode(..state, hop_count: state.hop_count + hops, request_count: state.request_count + 1)
      actor.continue(updated)
    }
    
    SuccessorFound(_succ, hops) -> {
      let updated = ChordNode(..state, hop_count: state.hop_count + hops, request_count: state.request_count + 1)
      actor.continue(updated)
    }
    
    StartBatch(keys) -> {
      let num_keys = list.length(keys)
      let delay_per_request = case num_keys {
        0 -> 0
        n -> case n > 50 {
          True -> 20
          False -> int.max(10, 100 / n)  // Adjust timing based on load
        }
      }
      
      list.index_fold(keys, Nil, fn(_acc, key, index) {
        case index > 0 && index % 10 == 0 {
          True -> process.sleep(delay_per_request)
          False -> Nil
        }
        
        case dict.get(state.all_nodes, state.id) {
          Ok(self_actor) -> {
            actor.send(self_actor, LookupValue(key, self_actor, 0))
          }
          Error(_) -> Nil
        }
        Nil
      })
      
      actor.continue(state)
    }
    ReportStats(coordinator) -> {
      actor.send(coordinator, StatsReceived(state.hop_count, state.request_count))
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}

fn is_between(key: NodeId, start: NodeId, end: NodeId) -> Bool {
  case start == end {
    True -> False
    False -> case start < end {
      True -> key > start && key <= end
      False -> key > start || key <= end
    }
  }
}

fn find_closest_finger(key: NodeId, state: ChordNode) -> NodeId {
  case list.reverse(state.finger_table) |> list.find(fn(finger) {
    is_between(finger.successor, state.id, key)
  }) {
    Ok(finger) -> finger.successor
    Error(_) -> state.successor
  }
}

fn start_coordinator(num_nodes: Int, num_requests: Int) -> Result(Subject(CoordinatorMessage), Nil) {
  let initial_state = Coordinator(num_nodes, num_requests * num_nodes, 0, 0)
  
  case actor.new(initial_state)
       |> actor.on_message(handle_coordinator_message)
       |> actor.start {
    Ok(started) -> Ok(started.data)
    Error(_) -> Error(Nil)
  }
}

fn handle_coordinator_message(state: Coordinator, message: CoordinatorMessage) -> actor.Next(Coordinator, CoordinatorMessage) {
  case message {
    StatsReceived(hops, _requests) -> {
      let updated = Coordinator(..state, collected_hops: state.collected_hops + hops, responses: state.responses + 1)
      case updated.responses == state.expected_nodes {
        True -> {
          io.println("Total hops collected: " <> int.to_string(updated.collected_hops))
          let average = int.to_float(updated.collected_hops) /. int.to_float(state.total_requests)
          io.println("Average number of hops: " <> float.to_string(average))
          actor.continue(updated)
        }
        False -> actor.continue(updated)
      }
    }
    Complete -> actor.stop()
  }
}

fn collect_results(actors: List(#(NodeId, Subject(ChordMessage))), coordinator: Subject(CoordinatorMessage), num_nodes: Int) {
  let base_wait_time = case num_nodes {
    n if n <= 50 -> 1000
    n if n <= 100 -> 2000
    n if n <= 500 -> 4000
    n if n <= 1000 -> 6000
    n if n <= 2000 -> 10000
    n if n <= 5000 -> 15000
    _ -> 25000
  }
  let batch_overhead = case num_nodes > 500 {
    True -> int.max(2000, num_nodes / 100 * 1000)
    False -> 0
  }
  let timing_overhead = case num_nodes > 100 {
    True -> 2000 
    False -> 1000
  }
  let total_wait_time = base_wait_time + batch_overhead + timing_overhead
  process.sleep(total_wait_time)
  list.index_fold(actors, Nil, fn(_acc, pair, index) {
    case index > 0 && index % 50 == 0 {
      True -> process.sleep(10)
      False -> Nil
    }
    actor.send(pair.1, ReportStats(coordinator))
    Nil
  })
  let processing_time = int.max(2000, num_nodes * 2)
  process.sleep(processing_time)
  actor.send(coordinator, Complete)
}
