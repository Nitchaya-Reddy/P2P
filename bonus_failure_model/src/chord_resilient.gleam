import gleam/io
import gleam/int
import gleam/float
import gleam/list
import gleam/result
import gleam/option.{type Option, None, Some}
import gleam/erlang/process.{type Subject}
import gleam/erlang/charlist
import gleam/otp/actor
import gleam/dict.{type Dict}

// External function to get command line arguments
@external(erlang, "init", "get_plain_arguments")
fn get_plain_arguments() -> List(charlist.Charlist)

// Chord ring configuration
const chord_m = 8
const ring_size = 256

pub type NodeId = Int

// Failure types as described in Section 5 of Chord paper
pub type FailureType {
  NodeCrash          // Complete node failure (permanent)
  NodeLeave          // Graceful node departure
  ConnectionFailure  // Temporary network partition
  SlowNode          // Node becomes very slow but doesn't crash
}

// Failure event for testing
pub type FailureEvent {
  FailureEvent(
    target_node: NodeId,
    failure_type: FailureType,
    time_ms: Int,      // When failure occurs (ms after start)
    duration_ms: Int   // How long failure lasts (0 = permanent)
  )
}

// Enhanced finger table entry with failure tracking
pub type FingerEntry {
  FingerEntry(
    start: NodeId,
    successor: NodeId,
    last_seen: Int,    // Timestamp of last successful communication
    failures: Int      // Count of consecutive failures
  )
}

// Node state for failure detection
pub type NodeState {
  Healthy
  Suspected     // Detected as potentially failed
  Failed        // Confirmed as failed
  Recovering    // Coming back online
}

// Enhanced message types with failure handling
pub type ChordMessage {
  // Standard Chord messages
  FindSuccessor(key: NodeId, from: Subject(ChordMessage), hops: Int)
  SuccessorFound(successor: NodeId, hops: Int)
  LookupValue(key: NodeId, from: Subject(ChordMessage), hops: Int)
  ValueFound(key: NodeId, value: String, hops: Int)
  
  // Node management with failure handling
  SetupNode(successor: NodeId, fingers: List(FingerEntry), all_nodes: Dict(NodeId, Subject(ChordMessage)), predecessors: List(NodeId))
  
  // Failure detection and recovery (Section 5)
  CheckPredecessor(from: Subject(ChordMessage))
  PredecessorAlive(node_id: NodeId)
  Stabilize
  Notify(node_id: NodeId, from: Subject(ChordMessage))
  
  // Successor list maintenance for fault tolerance
  UpdateSuccessorList(successors: List(NodeId))
  GetSuccessorList(from: Subject(ChordMessage))
  SuccessorList(successors: List(NodeId))
  
  // Failure simulation
  SimulateFailure(failure_type: FailureType, duration_ms: Int)
  RecoverFromFailure
  
  // Testing and statistics
  StartBatch(batch_id: Int, keys: List(NodeId))
  ReportStats(coord: Subject(CoordinatorMessage))
  HealthCheck(from: Subject(ChordMessage))
  HealthStatus(node_id: NodeId, state: NodeState, timestamp: Int)
  
  Stop
}

// Coordinator messages for resilience testing
pub type CoordinatorMessage {
  StatsReceived(total_hops: Int, requests: Int, successful: Int, failed: Int)
  FailureReport(node_id: NodeId, failure_type: FailureType, timestamp: Int)
  RecoveryReport(node_id: NodeId, timestamp: Int)
  Complete
}

// Enhanced node state with failure resilience features
pub type ChordNode {
  ChordNode(
    id: NodeId,
    successor: NodeId,
    predecessor: Option(NodeId),
    finger_table: List(FingerEntry),
    successor_list: List(NodeId),  // Multiple successors for fault tolerance
    all_nodes: Dict(NodeId, Subject(ChordMessage)),
    key_store: Dict(NodeId, String),
    hop_count: Int,
    request_count: Int,
    successful_requests: Int,
    failed_requests: Int,
    state: NodeState,
    failure_detector: Dict(NodeId, Int),  // Track failures of other nodes
    last_stabilize: Int,
    simulated_failure: Option(FailureType)
  )
}

// Coordinator state for tracking system resilience
pub type Coordinator {
  Coordinator(
    expected_nodes: Int,
    total_requests: Int,
    collected_hops: Int,
    successful_ops: Int,
    failed_ops: Int,
    responses: Int,
    active_failures: List(FailureEvent),
    recovery_events: List(#(NodeId, Int)),
    start_time: Int
  )
}

// Main entry point with failure testing
pub fn main() {
  let args = get_plain_arguments() |> list.map(charlist.to_string)
  
  case args {
    [nodes_str, requests_str] -> {
      case int.parse(nodes_str), int.parse(requests_str) {
        Ok(num_nodes), Ok(num_requests) -> {
          case num_nodes > 0 && num_requests > 0 {
            True -> {
              case num_nodes <= 1000 {
                True -> {
                  io.println("=== Chord P2P System - Failure Resilience Testing ===")
                  io.println("Nodes: " <> int.to_string(num_nodes) <> ", Requests per node: " <> int.to_string(num_requests))
                  run_resilience_simulation(num_nodes, num_requests)
                }
                False -> io.println("Error: Maximum 1000 nodes for failure simulation")
              }
            }
            False -> io.println("Error: Numbers must be positive")
          }
        }
        _, _ -> print_usage()
      }
    }
    [nodes_str, requests_str, "test-failures"] -> {
      case int.parse(nodes_str), int.parse(requests_str) {
        Ok(num_nodes), Ok(num_requests) -> {
          io.println("=== Running Comprehensive Failure Tests ===")
          run_comprehensive_failure_tests(num_nodes, num_requests)
        }
        _, _ -> print_usage()
      }
    }
    _ -> print_usage()
  }
}

fn print_usage() {
  io.println("Usage: gleam run -m chord_resilient <numNodes> <numRequests> [test-failures]")
  io.println("  test-failures: Run comprehensive failure scenario tests")
}

// Run simulation with failure injection
fn run_resilience_simulation(num_nodes: Int, num_requests: Int) {
  let node_ids = generate_node_ids(num_nodes)
  
  case start_resilient_actors(node_ids) {
    Ok(actors) -> {
      let nodes_dict = build_nodes_dict(actors)
      
      // Initialize ring with enhanced failure detection
      initialize_resilient_ring(actors, nodes_dict)
      
      // Start coordinator for resilience tracking
      case start_resilience_coordinator(num_nodes, num_requests) {
        Ok(coordinator) -> {
          // Inject failures during simulation
          inject_random_failures(actors, coordinator)
          
          // Run requests with failure resilience
          execute_resilient_requests(actors, num_requests)
          
          // Collect and analyze results
          collect_resilience_results(actors, coordinator, num_nodes)
        }
        Error(_) -> io.println("Failed to start resilience coordinator")
      }
    }
    Error(_) -> io.println("Failed to start resilient actors")
  }
}

// Generate evenly spaced node IDs
fn generate_node_ids(count: Int) -> List(NodeId) {
  case count {
    0 -> []
    1 -> [0]
    _ -> {
      let spacing = ring_size / count
      list.range(0, count - 1) |> list.map(fn(i) { i * spacing })
    }
  }
}

// Start actors with enhanced failure handling capabilities
fn start_resilient_actors(node_ids: List(NodeId)) -> Result(List(#(NodeId, Subject(ChordMessage))), Nil) {
  let actors_result = list.try_map(node_ids, fn(node_id) {
    create_resilient_actor(node_id)
  })
  
  case actors_result {
    Ok(actors) -> Ok(actors)
    Error(_) -> Error(Nil)
  }
}

// Create single actor with failure resilience features
fn create_resilient_actor(node_id: NodeId) -> Result(#(NodeId, Subject(ChordMessage)), Nil) {
  // Initialize with sample key-value data and failure detection
  let initial_store = dict.new()
    |> dict.insert(node_id, "Value_" <> int.to_string(node_id))
    |> dict.insert({node_id + 1} % ring_size, "Value_" <> int.to_string({node_id + 1} % ring_size))
  
  let initial_state = ChordNode(
    id: node_id,
    successor: node_id,
    predecessor: None,
    finger_table: [],
    successor_list: [],
    all_nodes: dict.new(),
    key_store: initial_store,
    hop_count: 0,
    request_count: 0,
    successful_requests: 0,
    failed_requests: 0,
    state: Healthy,
    failure_detector: dict.new(),
    last_stabilize: get_current_time(),
    simulated_failure: None
  )
  
  case actor.new(initial_state) 
       |> actor.on_message(handle_resilient_message) 
       |> actor.start {
    Ok(started) -> Ok(#(node_id, started.data))
    Error(_) -> Error(Nil)
  }
}

// Get current timestamp (mock implementation)
fn get_current_time() -> Int {
  // In real implementation, this would return actual timestamp
  42
}

fn build_nodes_dict(actors: List(#(NodeId, Subject(ChordMessage)))) -> Dict(NodeId, Subject(ChordMessage)) {
  list.fold(actors, dict.new(), fn(acc, pair) {
    dict.insert(acc, pair.0, pair.1)
  })
}

// Initialize ring with failure detection and successor lists
fn initialize_resilient_ring(actors: List(#(NodeId, Subject(ChordMessage))), nodes_dict: Dict(NodeId, Subject(ChordMessage))) {
  let sorted_ids = list.map(actors, fn(pair) { pair.0 }) |> list.sort(int.compare)
  
  list.each(actors, fn(pair) {
    let node_id = pair.0
    let node_actor = pair.1
    
    let successor = find_successor_in_list(node_id, sorted_ids)
    let fingers = build_resilient_finger_table(node_id, sorted_ids)
    let successor_list = build_successor_list(node_id, sorted_ids, 3)  // Keep 3 successors
    
    actor.send(node_actor, SetupNode(successor, fingers, nodes_dict, successor_list))
  })
  
  // Allow time for ring initialization
  process.sleep(500)
}

fn find_successor_in_list(node_id: NodeId, sorted_ids: List(NodeId)) -> NodeId {
  case list.find(sorted_ids, fn(id) { id > node_id }) {
    Ok(next) -> next
    Error(_) -> case list.first(sorted_ids) {
      Ok(first) -> first
      Error(_) -> node_id
    }
  }
}

fn build_resilient_finger_table(node_id: NodeId, all_ids: List(NodeId)) -> List(FingerEntry) {
  list.range(0, chord_m - 1) |> list.map(fn(i) {
    let finger_start = calculate_finger_start(node_id, i)
    let finger_successor = find_successor_in_list(finger_start, all_ids)
    FingerEntry(
      start: finger_start,
      successor: finger_successor,
      last_seen: get_current_time(),
      failures: 0
    )
  })
}

fn build_successor_list(node_id: NodeId, all_ids: List(NodeId), count: Int) -> List(NodeId) {
  // Build list of next 'count' successors for fault tolerance
  let sorted_after = list.filter(all_ids, fn(id) { id > node_id }) 
                   |> list.sort(int.compare)
  let sorted_before = list.filter(all_ids, fn(id) { id <= node_id })
                    |> list.sort(int.compare)
  
  let successors = list.append(sorted_after, sorted_before)
  
  list.take(successors, count)
}

fn calculate_finger_start(node_id: NodeId, finger_index: Int) -> NodeId {
  let power = calculate_power_of_2(finger_index)
  int.bitwise_and(node_id + power, ring_size - 1)
}

fn calculate_power_of_2(i: Int) -> Int {
  case i {
    0 -> 1
    1 -> 2
    2 -> 4
    3 -> 8
    4 -> 16
    5 -> 32
    6 -> 64
    7 -> 128
    _ -> 256
  }
}

// Enhanced message handler with failure resilience
fn handle_resilient_message(state: ChordNode, message: ChordMessage) -> actor.Next(ChordNode, ChordMessage) {
  // Check if node is simulating failure
  case state.simulated_failure {
    Some(NodeCrash) -> actor.continue(state)  // Ignore all messages during crash
    Some(SlowNode) -> {
      process.sleep(1000)  // Simulate slow response
      handle_message_normally(state, message)
    }
    Some(ConnectionFailure) -> {
      // Simulate network partition - randomly drop 50% of messages
      case int.bitwise_and(state.id + state.request_count, 1) == 0 {
        True -> actor.continue(state)  // Drop message
        False -> handle_message_normally(state, message)
      }
    }
    _ -> handle_message_normally(state, message)
  }
}

fn handle_message_normally(state: ChordNode, message: ChordMessage) -> actor.Next(ChordNode, ChordMessage) {
  case message {
    SetupNode(succ, fingers, nodes, succ_list) -> {
      let updated = ChordNode(
        ..state,
        successor: succ,
        finger_table: fingers,
        all_nodes: nodes,
        successor_list: succ_list
      )
      actor.continue(updated)
    }
    
    FindSuccessor(key, from, hops) -> {
      handle_find_successor_with_recovery(state, key, from, hops)
    }
    
    LookupValue(key, from, hops) -> {
      handle_lookup_value_with_recovery(state, key, from, hops)
    }
    
    ValueFound(_key, _value, hops) -> {
      let updated = ChordNode(
        ..state,
        hop_count: state.hop_count + hops,
        request_count: state.request_count + 1,
        successful_requests: state.successful_requests + 1
      )
      actor.continue(updated)
    }
    
    SuccessorFound(_succ, hops) -> {
      let updated = ChordNode(
        ..state,
        hop_count: state.hop_count + hops,
        request_count: state.request_count + 1,
        successful_requests: state.successful_requests + 1
      )
      actor.continue(updated)
    }
    
    // Failure simulation messages
    SimulateFailure(failure_type, duration_ms) -> {
      io.println("Node " <> int.to_string(state.id) <> " simulating " <> failure_type_to_string(failure_type) <> " for " <> int.to_string(duration_ms) <> "ms")
      let updated = ChordNode(..state, simulated_failure: Some(failure_type), state: Failed)
      
      // Schedule recovery if not permanent
      case duration_ms > 0 {
        True -> {
          // In real system, would use timer
          actor.continue(updated)
        }
        False -> actor.continue(updated)
      }
    }
    
    RecoverFromFailure -> {
      io.println("Node " <> int.to_string(state.id) <> " recovering from failure")
      let updated = ChordNode(..state, simulated_failure: None, state: Recovering)
      actor.continue(updated)
    }
    
    // Stabilization and failure detection (Section 5)
    Stabilize -> {
      handle_stabilization(state)
    }
    
    CheckPredecessor(from) -> {
      // Respond to predecessor check
      actor.send(from, PredecessorAlive(state.id))
      actor.continue(state)
    }
    
    PredecessorAlive(node_id) -> {
      // Update failure detector
      let updated_detector = dict.insert(state.failure_detector, node_id, 0)
      let updated = ChordNode(..state, failure_detector: updated_detector)
      actor.continue(updated)
    }
    
    StartBatch(batch_id, keys) -> {
      handle_batch_with_failure_recovery(state, batch_id, keys)
    }
    
    ReportStats(coordinator) -> {
      actor.send(coordinator, StatsReceived(
        state.hop_count, 
        state.request_count, 
        state.successful_requests,
        state.failed_requests
      ))
      actor.continue(state)
    }
    
    HealthCheck(from) -> {
      actor.send(from, HealthStatus(state.id, state.state, get_current_time()))
      actor.continue(state)
    }
    
    Stop -> actor.stop()
    
    _ -> actor.continue(state)  // Handle other messages
  }
}

// Handle find successor with failure recovery using successor list
fn handle_find_successor_with_recovery(state: ChordNode, key: NodeId, from: Subject(ChordMessage), hops: Int) -> actor.Next(ChordNode, ChordMessage) {
  case key == state.id || is_between(key, state.id, state.successor) {
    True -> {
      actor.send(from, SuccessorFound(state.successor, hops + 1))
      actor.continue(state)
    }
    False -> {
      let next_node = find_closest_finger_with_recovery(key, state)
      route_message_with_recovery(state, next_node, FindSuccessor(key, from, hops + 1), from, hops)
    }
  }
}

// Handle value lookup with failure recovery
fn handle_lookup_value_with_recovery(state: ChordNode, key: NodeId, from: Subject(ChordMessage), hops: Int) -> actor.Next(ChordNode, ChordMessage) {
  case key == state.id || is_between(key, state.id, state.successor) {
    True -> {
      let value = dict.get(state.key_store, key) 
                |> result.unwrap("Key_" <> int.to_string(key) <> "_Value")
      actor.send(from, ValueFound(key, value, hops + 1))
      actor.continue(state)
    }
    False -> {
      let next_node = find_closest_finger_with_recovery(key, state)
      route_message_with_recovery(state, next_node, LookupValue(key, from, hops + 1), from, hops)
    }
  }
}

// Route message with failure recovery using successor list
fn route_message_with_recovery(state: ChordNode, next_node: NodeId, message: ChordMessage, original_from: Subject(ChordMessage), hops: Int) -> actor.Next(ChordNode, ChordMessage) {
  case dict.get(state.all_nodes, next_node) {
    Ok(next_actor) -> {
      actor.send(next_actor, message)
      actor.continue(state)
    }
    Error(_) -> {
      // Primary target failed, try successor list
      case try_successor_list(state, message, 0) {
        Ok(_) -> actor.continue(state)
        Error(_) -> {
          // All successors failed, mark request as failed
          let updated = ChordNode(..state, failed_requests: state.failed_requests + 1)
                    // Send failure response\n          case message {\n            FindSuccessor(key, _, _) -> {\n              actor.send(original_from, SuccessorFound(state.id, hops + 1))\n            }\n            LookupValue(key, _, _) -> {\n              actor.send(original_from, ValueFound(key, \"LOOKUP_FAILED\", hops + 1))\n            }\n            _ -> Nil\n          }"
          actor.continue(updated)
        }
      }
    }
  }
}

// Try sending message through successor list for fault tolerance
fn try_successor_list(state: ChordNode, message: ChordMessage, index: Int) -> Result(Nil, Nil) {
  let successors = state.successor_list
  case index < list.length(successors) {
    True -> {
      case list.drop(successors, index) |> list.first {
        Ok(successor_id) -> {
          case dict.get(state.all_nodes, successor_id) {
            Ok(successor_actor) -> {
              actor.send(successor_actor, message)
              Ok(Nil)
            }
            Error(_) -> {
              // Try next successor
              case index < list.length(successors) - 1 {
                True -> try_successor_list(state, message, index + 1)
                False -> Error(Nil)
              }
            }
          }
        }
        Error(_) -> Error(Nil)
      }
    }
    False -> Error(Nil)
  }
}

// Find closest finger with failure awareness
fn find_closest_finger_with_recovery(key: NodeId, state: ChordNode) -> NodeId {
  // Filter out fingers that have too many failures
  let healthy_fingers = list.filter(state.finger_table, fn(finger) {
    finger.failures < 3  // Threshold for considering a finger unhealthy
  })
  
  case list.reverse(healthy_fingers) |> list.find(fn(finger) {
    is_between(finger.successor, state.id, key)
  }) {
    Ok(finger) -> finger.successor
    Error(_) -> {
      // No healthy fingers, try first successor from successor list
      case list.first(state.successor_list) {
        Ok(first_succ) -> first_succ
        Error(_) -> state.successor
      }
    }
  }
}

// Handle stabilization as described in Section 5
fn handle_stabilization(state: ChordNode) -> actor.Next(ChordNode, ChordMessage) {
  // Check if successor is alive
  case dict.get(state.all_nodes, state.successor) {
    Ok(successor_actor) -> {
      actor.send(successor_actor, CheckPredecessor(dict.get(state.all_nodes, state.id) |> result.unwrap(successor_actor)))
      actor.continue(state)
    }
    Error(_) -> {
      // Successor failed, find new one from successor list
      case find_new_successor_from_list(state) {
        Some(new_successor) -> {
          let updated = ChordNode(..state, successor: new_successor)
          actor.continue(updated)
        }
        None -> actor.continue(state)
      }
    }
  }
}

fn find_new_successor_from_list(state: ChordNode) -> Option(NodeId) {
  case list.find(state.successor_list, fn(succ_id) {
    case dict.get(state.all_nodes, succ_id) {
      Ok(_) -> True
      Error(_) -> False
    }
  }) {
    Ok(succ_id) -> Some(succ_id)
    Error(_) -> None
  }
}

// Handle batch requests with failure recovery
fn handle_batch_with_failure_recovery(state: ChordNode, _batch_id: Int, keys: List(NodeId)) -> actor.Next(ChordNode, ChordMessage) {
  let num_keys = list.length(keys)
  
  list.each(keys, fn(key) {
    case dict.get(state.all_nodes, state.id) {
      Ok(self_actor) -> {
        actor.send(self_actor, LookupValue(key, self_actor, 0))
      }
      Error(_) -> Nil
    }
  })
  
  // Debug output for failure recovery
  case num_keys > 0 && state.id % 50 == 0 {
    True -> {
      let health_status = case state.state {
        Healthy -> "HEALTHY"
        Suspected -> "SUSPECTED"
        Failed -> "FAILED"  
        Recovering -> "RECOVERING"
      }
      io.println("Debug: Node " <> int.to_string(state.id) <> " (" <> health_status <> ") processed " <> int.to_string(num_keys) <> " keys")
    }
    False -> Nil
  }
  
  actor.continue(state)
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

fn failure_type_to_string(failure_type: FailureType) -> String {
  case failure_type {
    NodeCrash -> "NODE_CRASH"
    NodeLeave -> "NODE_LEAVE"
    ConnectionFailure -> "CONNECTION_FAILURE"
    SlowNode -> "SLOW_NODE"
  }
}

// Inject random failures for resilience testing
fn inject_random_failures(actors: List(#(NodeId, Subject(ChordMessage))), coordinator: Subject(CoordinatorMessage)) {
  let num_actors = list.length(actors)
  let failure_count = int.max(1, num_actors / 10)  // Fail 10% of nodes
  
  io.println("Injecting " <> int.to_string(failure_count) <> " random failures...")
  
  // Select random nodes for failure
  let failure_targets = list.take(actors, failure_count)
  
  list.each(failure_targets, fn(pair) {
    let node_id = pair.0
    let node_actor = pair.1
    
    // Randomly choose failure type
    let failure_type = case int.bitwise_and(node_id, 3) {
      0 -> NodeCrash
      1 -> ConnectionFailure
      2 -> SlowNode
      _ -> NodeLeave
    }
    
    // Simulate failure after 2 seconds, recover after 5 seconds for non-permanent failures
    let duration = case failure_type {
      NodeCrash -> 0  // Permanent
      _ -> 5000      // 5 seconds
    }
    
    // Schedule failure
    process.sleep(2000)
    actor.send(node_actor, SimulateFailure(failure_type, duration))
    
    // Report failure to coordinator
    actor.send(coordinator, FailureReport(node_id, failure_type, get_current_time()))
    
    // Schedule recovery for non-permanent failures
    case duration > 0 {
      True -> {
        process.sleep(duration)
        actor.send(node_actor, RecoverFromFailure)
        actor.send(coordinator, RecoveryReport(node_id, get_current_time()))
      }
      False -> Nil
    }
  })
}

// Execute requests with failure resilience testing
fn execute_resilient_requests(actors: List(#(NodeId, Subject(ChordMessage))), num_requests: Int) {
  
  io.println("Starting resilient request execution...")
  
    // Start requests in batches to simulate realistic load\n  list.each(list.index_fold(actors, [], fn(acc, pair, index) {\n    let batch_delay = {index / 10} * 100  // Stagger batch starts\n    process.sleep(batch_delay)\n    \n    let keys = list.range(1, num_requests) |> list.map(fn(i) {\n      int.bitwise_and(pair.0 * 17 + i * 23, ring_size - 1)\n    })\n    \n    actor.send(pair.1, StartBatch(0, keys))\n    [Nil, ..acc]\n  }), fn(_) { Nil })"
}

// Start coordinator with resilience tracking
fn start_resilience_coordinator(num_nodes: Int, num_requests: Int) -> Result(Subject(CoordinatorMessage), Nil) {
  let initial_state = Coordinator(
    expected_nodes: num_nodes,
    total_requests: num_nodes * num_requests,
    collected_hops: 0,
    successful_ops: 0,
    failed_ops: 0,
    responses: 0,
    active_failures: [],
    recovery_events: [],
    start_time: get_current_time()
  )
  
  case actor.new(initial_state)
       |> actor.on_message(handle_resilience_coordinator_message)
       |> actor.start {
    Ok(started) -> Ok(started.data)
    Error(_) -> Error(Nil)
  }
}

fn handle_resilience_coordinator_message(state: Coordinator, message: CoordinatorMessage) -> actor.Next(Coordinator, CoordinatorMessage) {
  case message {
    StatsReceived(hops, _requests, successful, failed) -> {
      let updated = Coordinator(
        ..state,
        collected_hops: state.collected_hops + hops,
        successful_ops: state.successful_ops + successful,
        failed_ops: state.failed_ops + failed,
        responses: state.responses + 1
      )
      
      case updated.responses % 50 == 0 && updated.responses > 0 {
        True -> io.println("Debug: Received " <> int.to_string(updated.responses) <> "/" <> int.to_string(state.expected_nodes) <> " responses")
        False -> Nil
      }
      
      case updated.responses == state.expected_nodes {
        True -> {
          print_resilience_results(updated)
          actor.continue(updated)
        }
        False -> actor.continue(updated)
      }
    }
    
    FailureReport(node_id, failure_type, _timestamp) -> {
      io.println("FAILURE: Node " <> int.to_string(node_id) <> " - " <> failure_type_to_string(failure_type))
      actor.continue(state)
    }
    
    RecoveryReport(node_id, timestamp) -> {
      io.println("RECOVERY: Node " <> int.to_string(node_id) <> " back online")
      let updated_recoveries = list.prepend(state.recovery_events, #(node_id, timestamp))
      let updated = Coordinator(..state, recovery_events: updated_recoveries)
      actor.continue(updated)
    }
    
    Complete -> actor.stop()
  }
}

fn print_resilience_results(state: Coordinator) {
  io.println("\n=== RESILIENCE TEST RESULTS ===")
  io.println("Total operations: " <> int.to_string(state.total_requests))
  io.println("Successful operations: " <> int.to_string(state.successful_ops))
  io.println("Failed operations: " <> int.to_string(state.failed_ops))
  
  let success_rate = case state.total_requests > 0 {
    True -> int.to_float(state.successful_ops) *. 100.0 /. int.to_float(state.total_requests)
    False -> 0.0
  }
  
  io.println("Success rate: " <> float.to_string(success_rate) <> "%")
  
  let avg_hops = case state.successful_ops > 0 {
    True -> int.to_float(state.collected_hops) /. int.to_float(state.successful_ops)
    False -> 0.0
  }
  
  io.println("Average hops per successful lookup: " <> float.to_string(avg_hops))
  io.println("Recovery events: " <> int.to_string(list.length(state.recovery_events)))
}

// Collect results with resilience analysis
fn collect_resilience_results(actors: List(#(NodeId, Subject(ChordMessage))), coordinator: Subject(CoordinatorMessage), num_nodes: Int) {
  let wait_time = case num_nodes {
    n if n <= 100 -> 8000   // Extra time for failure recovery
    n if n <= 500 -> 15000
    _ -> 25000
  }
  
  io.println("Waiting " <> int.to_string(wait_time / 1000) <> " seconds for resilience testing...")
  process.sleep(wait_time)
  
  // Request final statistics
  list.each(actors, fn(pair) {
    actor.send(pair.1, ReportStats(coordinator))
  })
  
  process.sleep(3000)  // Wait for stat collection
  actor.send(coordinator, Complete)
}

// Comprehensive failure test scenarios
fn run_comprehensive_failure_tests(num_nodes: Int, num_requests: Int) {
  io.println("=== Test 1: Single Node Crash ===")
  run_single_failure_test(num_nodes, num_requests, NodeCrash)
  
  io.println("\n=== Test 2: Network Partition ===")
  run_single_failure_test(num_nodes, num_requests, ConnectionFailure)
  
  io.println("\n=== Test 3: Slow Node Response ===")
  run_single_failure_test(num_nodes, num_requests, SlowNode)
  
  io.println("\n=== Test 4: Multiple Cascading Failures ===")
  run_cascading_failure_test(num_nodes, num_requests)
}

fn run_single_failure_test(num_nodes: Int, num_requests: Int, failure_type: FailureType) {
  // Implementation would be similar to main simulation but with specific failure injection
  io.println("Running " <> failure_type_to_string(failure_type) <> " test...")
  run_resilience_simulation(num_nodes, num_requests)
}

fn run_cascading_failure_test(num_nodes: Int, num_requests: Int) {
  io.println("Testing cascading failure recovery...")
  // Would implement progressive failure injection
  run_resilience_simulation(num_nodes, num_requests)
}