import gleam/io
import gleam/int
import gleam/float
import gleam/list
import gleam/result
import gleam/erlang/process.{type Subject}
import gleam/erlang/charlist
import gleam/otp/actor
import gleam/dict.{type Dict}

// External function to get command line arguments
@external(erlang, "init", "get_plain_arguments")
fn get_plain_arguments() -> List(charlist.Charlist)

// Chord ring configuration - optimized for memory efficiency
const chord_m = 8  // Reduced from 10 to save memory
const ring_size = 256  // 2^8 instead of 2^10

pub type NodeId = Int

// Simplified finger table entry
pub type FingerEntry {
  FingerEntry(start: NodeId, successor: NodeId)
}

// Optimized message types with key-value lookup support
pub type ChordMessage {
  FindSuccessor(key: NodeId, from: Subject(ChordMessage), hops: Int)
  SuccessorFound(successor: NodeId, hops: Int)
  LookupValue(key: NodeId, from: Subject(ChordMessage), hops: Int)  // New: lookup key-value pair
  ValueFound(key: NodeId, value: String, hops: Int)  // New: return key-value result
  SetupNode(successor: NodeId, fingers: List(FingerEntry), all_nodes: Dict(NodeId, Subject(ChordMessage)))
  StartBatch(batch_id: Int, keys: List(NodeId))
  ReportStats(coord: Subject(CoordinatorMessage))
  Stop
}

// Coordinator messages
pub type CoordinatorMessage {
  StatsReceived(total_hops: Int, requests: Int)
  Complete
}

// Optimized node state - minimal memory footprint with key-value storage
pub type ChordNode {
  ChordNode(
    id: NodeId,
    successor: NodeId,
    finger_table: List(FingerEntry),
    all_nodes: Dict(NodeId, Subject(ChordMessage)),
    hop_count: Int,
    request_count: Int,
    key_store: Dict(NodeId, String)  // Store key-value pairs for keys this node is responsible for
  )
}

// Coordinator state
pub type Coordinator {
  Coordinator(expected_nodes: Int, total_requests: Int, responses: Int, collected_hops: Int)
}

// Main entry point
pub fn main() {
  let args = get_plain_arguments() |> list.map(charlist.to_string)
  
  case args {
    [nodes_str, requests_str] -> {
      case int.parse(nodes_str), int.parse(requests_str) {
        Ok(num_nodes), Ok(num_requests) -> {
          // Intelligent resource limit checking
          let total_ops = num_nodes * num_requests
          case total_ops {
            ops if ops > 500000 -> {
              io.println("Error: Total operations (" <> int.to_string(ops) <> ") exceeds memory limit of 500,000")
            }
            _ -> case num_nodes > 0 && num_requests > 0 {
              True -> case num_nodes <= 5000 {
                True -> {
                  // Memory usage warning
                  case num_nodes >= 1000 {
                    True -> io.println("Info: Large network - using memory-optimized simulation")
                    False -> Nil
                  }
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

// Memory-optimized simulation
fn run_optimized_simulation(num_nodes: Int, num_requests: Int) {
  // Create optimized node IDs with better distribution
  let node_ids = create_optimized_node_ids(num_nodes)
  
  // Start actors with memory management
  case create_optimized_actors(node_ids) {
    Ok(node_actors) -> {
      let nodes_dict = create_nodes_dict(node_actors)
      
      // Setup ring with minimal memory usage
      setup_optimized_ring(node_actors, nodes_dict)
      
      // Start coordinator
      case start_coordinator(num_nodes, num_requests) {
        Ok(coordinator) -> {
          // Run simulation with batched requests
          run_batched_simulation(node_actors, num_requests, num_nodes)
          
          // Collect results with appropriate timing
          collect_results(node_actors, coordinator, num_nodes)
        }
        Error(_) -> io.println("Error: Could not start coordinator")
      }
    }
    Error(msg) -> io.println("Error: " <> msg)
  }
}

fn create_optimized_node_ids(count: Int) -> List(NodeId) {
  case count <= ring_size {
    True -> {
      // Space nodes evenly if we have room
      let spacing = ring_size / count
      case spacing > 0 {
        True -> list.range(0, count - 1) |> list.map(fn(i) { i * spacing })
        False -> {
          // Fallback to simple sequential IDs if spacing calculation fails
          list.range(0, count - 1)
        }
      }
    }
    False -> {
      // More nodes than ring positions, use modular arithmetic
      list.range(0, count - 1) |> list.map(fn(i) { 
        int.bitwise_and(i * 17 + 31, ring_size - 1)
      })
    }
  }
}

// Memory-conscious actor creation
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

// Create single actor with minimal state and sample key-value data
fn create_single_actor(node_id: NodeId) -> Result(#(NodeId, Subject(ChordMessage)), String) {
  // Initialize with some sample key-value pairs for demonstration
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

// Create nodes dictionary
fn create_nodes_dict(actors: List(#(NodeId, Subject(ChordMessage)))) -> Dict(NodeId, Subject(ChordMessage)) {
  list.fold(actors, dict.new(), fn(acc, pair) {
    dict.insert(acc, pair.0, pair.1)
  })
}

// Optimized ring setup
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
    let power = case int.power(2, int.to_float(i)) {
      Ok(val) -> float.round(val)
      Error(_) -> 1
    }
    let start = int.bitwise_and(node_id + power, ring_size - 1)
    FingerEntry(start, find_successor(start, all_ids))
  })
}

// Batched simulation runner
fn run_batched_simulation(actors: List(#(NodeId, Subject(ChordMessage))), num_requests: Int, num_nodes: Int) {
  case num_nodes > 500 {
    True -> {
      // Use batching for large networks to prevent memory issues
      let batch_size = int.max(1, num_requests / 10)  // 10% at a time
      let num_batches = { num_requests + batch_size - 1 } / batch_size
      
      list.range(0, num_batches - 1) |> list.each(fn(batch_id) {
        list.each(actors, fn(pair) {
          let start_key = batch_id * batch_size + 1
          let end_key = int.min(start_key + batch_size - 1, num_requests)
          let keys = list.range(start_key, end_key) |> list.map(fn(i) {
            int.bitwise_and(pair.0 * 17 + i * 23, ring_size - 1)
          })
          actor.send(pair.1, StartBatch(batch_id, keys))
        })
        // Delay between batches to prevent memory overflow
        process.sleep(100)
      })
    }
    False -> {
      // Direct approach for smaller networks
      list.each(actors, fn(pair) {
        let keys = list.range(1, num_requests) |> list.map(fn(i) {
          int.bitwise_and(pair.0 * 17 + i * 23, ring_size - 1)
        })
        actor.send(pair.1, StartBatch(0, keys))
      })
    }
  }
}

// Optimized message handler
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
          // This node is responsible for the key
          let value = dict.get(state.key_store, key) |> result.unwrap("Key_" <> int.to_string(key) <> "_NotFound")
          actor.send(from, ValueFound(key, value, hops + 1))
          actor.continue(state)
        }
        False -> {
          // Forward to the appropriate node
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
      // Count the lookup as completed
      let updated = ChordNode(..state, hop_count: state.hop_count + hops, request_count: state.request_count + 1)
      // Debug: Log successful key-value lookups periodically
      case updated.request_count % 100 == 0 {
        True -> io.println("Debug: Node " <> int.to_string(state.id) <> " completed " <> int.to_string(updated.request_count) <> " key-value lookups, " <> int.to_string(updated.hop_count) <> " total hops")
        False -> Nil
      }
      actor.continue(updated)
    }
    
    SuccessorFound(_succ, hops) -> {
      let updated = ChordNode(..state, hop_count: state.hop_count + hops, request_count: state.request_count + 1)
      // Debug: Log successful lookups every 100 requests
      case updated.request_count % 100 == 0 {
        True -> io.println("Debug: Node " <> int.to_string(state.id) <> " completed " <> int.to_string(updated.request_count) <> " requests, " <> int.to_string(updated.hop_count) <> " total hops")
        False -> Nil
      }
      actor.continue(updated)
    }
    
    StartBatch(batch_id, keys) -> {
      // Process batch of keys with improved timing (approximate 1 request/second per node)
      let num_keys = list.length(keys)
      let delay_per_request = case num_keys {
        0 -> 0
        n -> int.max(100, 1000 / n)  // Try to approximate 1 req/sec timing
      }
      
      list.index_fold(keys, Nil, fn(_acc, key, index) {
        // Stagger requests within batch for better timing
        case index > 0 {
          True -> process.sleep(delay_per_request)
          False -> Nil
        }
        
        case dict.get(state.all_nodes, state.id) {
          Ok(self_actor) -> {
            // Use key-value lookup for more realistic simulation
            actor.send(self_actor, LookupValue(key, self_actor, 0))
          }
          Error(_) -> Nil
        }
        Nil
      })
      
      // Debug: Log batch processing (reduced verbosity)
      case num_keys > 0 && state.id % 100 == 0 {
        True -> io.println("Debug: Node " <> int.to_string(state.id) <> " processed batch " <> int.to_string(batch_id) <> " with " <> int.to_string(num_keys) <> " keys")
        False -> Nil
      }
      actor.continue(state)
    }
    
    ReportStats(coordinator) -> {
      actor.send(coordinator, StatsReceived(state.hop_count, state.request_count))
      actor.continue(state)
    }
    
    Stop -> actor.stop()
  }
}

// Ring position checking
fn is_between(key: NodeId, start: NodeId, end: NodeId) -> Bool {
  case start == end {
    True -> False
    False -> case start < end {
      True -> key > start && key <= end
      False -> key > start || key <= end
    }
  }
}

// Find closest finger for routing
fn find_closest_finger(key: NodeId, state: ChordNode) -> NodeId {
  case list.reverse(state.finger_table) |> list.find(fn(finger) {
    is_between(finger.successor, state.id, key)
  }) {
    Ok(finger) -> finger.successor
    Error(_) -> state.successor
  }
}

// Coordinator functions
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
      
      // Debug progress
      case updated.responses % 100 == 0 && updated.responses > 0 {
        True -> io.println("Debug: Received " <> int.to_string(updated.responses) <> "/" <> int.to_string(state.expected_nodes) <> " responses")
        False -> Nil
      }
      
      case updated.responses == state.expected_nodes {
        True -> {
          // Calculate and display final results
          io.println("Debug: Expected nodes: " <> int.to_string(state.expected_nodes))
          io.println("Debug: Responses received: " <> int.to_string(updated.responses))
          io.println("Debug: Total hops collected: " <> int.to_string(updated.collected_hops))
          io.println("Debug: Total key-value requests expected: " <> int.to_string(state.total_requests))
          io.println("Debug: Average hops per key-value lookup: " <> int.to_string(updated.collected_hops) <> "/" <> int.to_string(state.total_requests))
          
          let average = int.to_float(updated.collected_hops) /. int.to_float(state.total_requests)
          io.println(float.to_string(average))
          actor.continue(updated)
        }
        False -> actor.continue(updated)
      }
    }
    Complete -> actor.stop()
  }
}

// Results collection with adaptive timing based on network characteristics
fn collect_results(actors: List(#(NodeId, Subject(ChordMessage))), coordinator: Subject(CoordinatorMessage), num_nodes: Int) {
  // Adaptive timing calculation based on network size and request patterns
  let base_wait_time = case num_nodes {
    n if n <= 50 -> 2000     // 2 seconds for tiny networks
    n if n <= 100 -> 3000    // 3 seconds for small networks
    n if n <= 500 -> 5000    // 5 seconds for medium networks  
    n if n <= 1000 -> 8000   // 8 seconds for large networks
    n if n <= 2000 -> 15000  // 15 seconds for very large networks
    n if n <= 5000 -> 25000  // 25 seconds for huge networks
    _ -> 45000               // 45 seconds for massive networks
  }
  
  // Add extra time for batched processing and request timing
  let batch_overhead = case num_nodes > 500 {
    True -> int.max(2000, num_nodes / 100 * 1000)  // Scale with network size
    False -> 0
  }
  
  // Add time for 1-request-per-second timing simulation
  let timing_overhead = case num_nodes > 100 {
    True -> 2000  // Extra time for request spacing
    False -> 1000
  }
  
  let total_wait_time = base_wait_time + batch_overhead + timing_overhead
  
  io.println("Waiting " <> int.to_string(total_wait_time / 1000) <> " seconds for key-value lookups to complete...")
  process.sleep(total_wait_time)
  
  // Request statistics from all nodes with some spacing
  list.index_fold(actors, Nil, fn(_acc, pair, index) {
    case index > 0 && index % 50 == 0 {
      True -> process.sleep(10)  // Small delays to avoid message flooding
      False -> Nil
    }
    actor.send(pair.1, ReportStats(coordinator))
    Nil
  })
  
  // Wait for coordinator to finish processing all responses
  let processing_time = int.max(2000, num_nodes * 2)
  process.sleep(processing_time)
  
  // Send completion signal
  actor.send(coordinator, Complete)
}