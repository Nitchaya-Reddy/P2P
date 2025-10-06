# Project 3 : Chord Protocol using Actor Model (Gleam)

## Team Members
- Nitchaya Reddy  
- Chinmai Mandala  

---

##  Project Overview
This project is an application of the **Chord Protocol**, a distributed lookup service for peer-to-peer (P2P) systems, built using **Gleam** and the **Actor Model**.  
Chord allows a decentralized network to efficiently locate the node responsible for a given key, even as nodes dynamically join or leave.  
It demonstrates scalability, fault tolerance, and distributed consistency.

The implementation follows the design from:  
📄 *"Chord: A Scalable Peer-to-Peer Lookup Service for Internet Applications"*  
by Ion Stoica et al. — [MIT CSAIL Paper](https://pdos.csail.mit.edu/papers/ton:chord/paper-ton.pdf)

---

## Project Objective

The goal of this project is to implement and evaluate the Chord protocol as a **scalable lookup mechanism** in a distributed environment.  
The objective is to demonstrate **logarithmic routing efficiency**, **decentralized control**, and **system stability** under dynamic peer participation using the **Actor Model** in Gleam.

---

##  Technologies & Tools Used

| Tool | Purpose |
|------|----------|
| **Gleam** | Functional programming language for building concurrent systems |
| **Erlang/OTP** | Backend runtime enabling actor-based concurrency |
| **gleam_otp** | Provides process management and message passing framework |
| **gleam_stdlib** | Core standard library for Gleam language |
| **Bash** | Used for simulation and automation (`run_optimized.sh`) |

---

##  Core Features Implemented
- Overlay network creation using unique node identifiers  
- Finger table routing for logarithmic lookups  
- Node join and stabilization protocols  
- Distributed key–value storage using consistent hashing  
- Actor-based message passing and concurrency  
- Hop count calculation and average hop reporting  

---

##  Repository Structure

```
Project - 3/
├── README.md                     # This file
├── gleam.toml                    # Basic project configuration  
├── src/
│   ├──project3_optimized.gleam   # Memory-optimized version 
├── test/          # BONUS: Failure resilience implementation
│   ├── chord_p2p_test            # test p2p
├── run_p2p.sh
├── manifest.toml
```

---

##  Core Implementation 

### 1. System Initialization
- The simulation starts by reading input parameters: number of nodes and number of requests per node.  
- Each node is created as an **independent actor process**, ensuring concurrency and isolation.  
- The first node forms the **initial Chord ring**, while subsequent nodes **join dynamically**.  
- Every node is assigned a **unique identifier (ID)** within the identifier space.  

---

### 2. Actor Behavior and Communication
- Each node runs as a **Gleam OTP actor** with its own state and mailbox.  
- Communication between nodes occurs through **asynchronous message passing**.  
- No shared memory is used — all coordination occurs via message exchange.  
- Actors handle messages like “Join,” “FindSuccessor,” “Lookup,” and “Stabilize.”  
- This architecture enables **parallel execution** and avoids synchronization bottlenecks.  

---

### 3. Node Join Process
- When a new node joins, it identifies its **correct position** in the ring.  
- It contacts a known node to find its **successor** (the next clockwise node).  
- The node initializes its **finger table**, successor, and predecessor pointers.  
- Neighboring nodes adjust their pointers to maintain **network consistency**.  

---

### 4. Finger Table Construction and Maintenance
- Each node maintains a **finger table**, mapping exponentially spaced nodes around the ring.  
- This allows efficient lookups by skipping multiple nodes per hop.  
- Periodic **FixFingers** messages refresh table entries for accuracy.  
- Routing paths remain near-optimal even with new node joins.  

---

### 5. Lookup and Routing
- Nodes receiving lookup requests first check if the key belongs to their range.  
- If not, they forward the query to the **closest preceding node** in their finger table.  
- Each hop brings the query closer to the correct node, yielding `O(log N)` efficiency.  
- The hop counter tracks the number of traversed nodes for performance metrics.  

---

### 6. Stabilization and Consistency
- Nodes periodically run **stabilization routines** to verify successor and predecessor accuracy.  
- If discrepancies are detected (due to new joins or delayed updates), they are corrected automatically.  
- This ensures the ring remains **consistent and connected** at all times.  

---

### 7. Key–Value Storage Layer
- Each key-value pair is stored on the node with the **closest ID ≥ key hash**.  
- Lookups traverse the ring to locate the responsible node.  
- This mirrors real-world DHT-based systems like **Amazon Dynamo** and **Cassandra**.  
- Demonstrates the practicality of Chord for distributed data storage.  

---

### 8. Hop Count Measurement and Output
- Each request records the number of hops during lookup.  
- When all nodes finish their requests, the total hops are aggregated.  
- The program prints the **average number of hops**, verifying logarithmic scalability.  

---

### 9. Memory Optimization and Scalability
- The `run_optimized.sh` script enables large-scale testing with reduced memory footprint.  
- Supports simulations up to **2000 nodes** efficiently.  
- Warns users when running potentially intensive workloads.  

---

## Testing and Results

| Test Scenario | # Nodes | # Requests | Avg Hops | Observations |
|----------------|----------|-------------|-----------|----------------|
| Small Network | 10 | 5 | ~2.3 | Stable and consistent routing |
| Medium Network | 100 | 10 | ~4.9 | Lookup scales logarithmically |
| Large Network | 1000 | 10 | ~9.8 | Expected logarithmic hop increase |
| Max Stable | 2000 | 10 | ~10–12 | Stable but memory-intensive |

---

## Performance Insights
- Lookup efficiency closely follows `O(log N)` behavior.  
- Average hops roughly double when network size increases tenfold.  
- Actor model ensures **high concurrency** and **low contention**.  
- System remains consistent and scalable under dynamic joins.  

---

## Observations

- Chord achieves decentralized and fault-tolerant lookups efficiently.  
- Actor-based design in Gleam provides natural concurrency.  
- Stabilization maintains accurate routing tables during network changes.  
- Memory optimization extends scalability for large test cases.  

---

## Bonus Work – Failure Model Extension
The `bonus_failure_model` folder extends Chord with **fault tolerance**.  
It introduces:  
- Failure detection and recovery mechanisms.  
- Periodic replica updates to prevent data loss.  
- A resilience layer ensuring consistent routing under churn.  
These improvements demonstrate Chord’s adaptability to real-world distributed network conditions.

---

## How to Run

### Steps

```bash
gleam build
chmod +x run_optimized.sh
./run_optimized.sh <numNodes> <numRequests>
```

Manual execution:

```bash
gleam run -m project3_optimized <numNodes> <numRequests>
```

