A Template for Writing a Microarchitecture Specification
banner
Architecture and microarchitecture are two different levels of abstraction. The former is about the hardware/software interface; the latter is about the hardware implementation. The microarchitect crafts a source of truth for the hardware team to anchor their work on.

Like any well-written work, a microarchitecture specification requires the author to understand their audience. They include a variety of engineering roles: logic design (RTL), simulated verification, formal verification, physical design, power, reliability, and performance modeling. Each of them is looking for different information, and the microarchitecture specification is the source of truth.

In this post, I present a template for writing a microarchitecture specification, organized in a way that makes it easy for your audience to get the information they need. I assume that you are already familiar with the concepts of microarchitecture and RTL design, and you’re looking for a way to better work cross-functionally. The template is intended for large blocks with significant complexity in an ASIC development process. Examples might include a memory controller, router, DMA engine, PCIe controller, vector unit, CPU datapath, etc.

If done well, the microarchitecture specification is a living document that evolves with the design, and it can be a valuable resource for new team members who join the project.

You may copy-paste this template for your own purposes without restriction (but please give attribution by citing this page).

1. <Block Name>
Start with a name of the block and provide author information.

1. Change Log
Continually maintain the following table of major and minor revisions to the spec, even if using a version control system like Git. Use a common version naming convention that can be shared with other related blocks. Always write dates in ISO standard form, i.e., YYYY-MM-DD.

Date	Version	Change Description	Authors	Reviewers
YYYY-MM-DD

v0.1

First draft

<names>

<names>

3. Overview
1-2 page description of the block. Briefly cover at a high level what it does and show a "birds-eye" black-box view of the top-level. Discuss goals and non-goals, how it is intended to integrate into a larger system, list any standard protocols, highlight important performance requirements, touch on debugging features, and describe physical design assumptions (floorplanning, timing, area, power, pin placement, reliability targets) and other relevant silicon considerations. Outline the design methodology (coding language, in-house and third-party libraries & IPs) and anything else that a verification engineer should know before writing their first draft of the test plan.

4. High-Level Requirements
In a few paragraphs, outline the key high-level design requirements for this block — carefully distinguish between functionality (behavior) and performance. It may also be helpful to define explicit non-goals. Non-exhaustive list of things to think about: clock frequencies and reset ordering; types of transactions and the interfaces they involve; transaction concurrency within and across interfaces; side effects from transactions; ordering requirements; flow control mechanisms; arbitration policies, fairness, and deadlock avoidance guarantees; transaction routing; performance; debuggability.

5. Top-Level Block Diagram
The top-level block diagram should indicate the block boundary and all major interfaces. Draw the top-level submodules and how they connect internally, but avoid showing an excessive amount of internal implementation detail. The structure of the top-level block diagram should correspond 1:1 with the contents of the top-level RTL module. Avoid "free-floating" logic at the top level (everything should be encapsulated in submodules).

6. Parameters and Typedefs
Maintain tables of typedefs and design parameters. Include major package parameters (both block-private and shared), top-level module parameters, and preprocessor macros that set global constants. Do not include parameters or macros that are calculated from others. Make sure to describe any constraints and any assumptions about reasonable or default values. Only define the types that are necessary to fully define the parameters and interfaces.

Type	Definition	Scope	Description
<placeholder>

Parameter	Type	Scope	Description
<placeholder>

7. Interfaces
Maintain a table of top-level interfaces. Group related ports as a single interface. Show the ports directions and types, describe what the interface is used for, and follow common naming conventions. Mention the use of any standard protocols. Avoid excessive abbreviations. The port directions, types, and names should match 1:1 with the RTL ports. Port directions should be from the block’s perspective (just like in RTL).

Interface	Port Direction	Port Type	Port Name	Description
<placeholder>

8. Protocols
For all interfaces that use a standard industry protocol or an internal/proprietary protocol, list them here and link to the relevant specifications that govern those protocols. If any interfaces use custom protocols that are not defined elsewhere, then define them in detail here, with one subsection per protocol. Make sure to define any protocols that involve more than one interface.

9. Clocks
Maintain a table of clock domains used in the design. For each clock, state its nominal frequency and the supported dynamic range. Show the same top-level block diagram as before, but this time annotate it to show which submodules are in each clock domain. Datapath clock domain crossings should be drawn explicitly, and they should be encapsulated within one or more submodules. For clocks that are used for "backbone" functions that span many submodules (e.g., a CSR bus on its own clock domain), state this clearly and defer the details to another appropriate document or section.

Clock	Nominal Frequency	Description
<placeholder>

10. Resets
Maintain a table of reset domains used in the design. For each reset, state whether it is synchronous or asynchronous; active high or active low; and if synchronous, to which clock. Show the same top-level block diagram as before, but this time annotate it to show which submodules are in each reset domain. Datapath reset domain crossings should be drawn explicitly, and they should be encapsulated within one or more submodules. For resets that are used for "backbone" functions that span many submodules (e.g., a CSR bus on its own reset domain), state this clearly and defer the details to another appropriate document or section. If the reset protocol is custom to this block, include a subsection that defines the relevant procedures. Otherwise, cite other documents that provide these details.

Reset	Kind	Description
<placeholder>

11. Example Transactions
At this point in the document, the reader should have enough context to understand a few detailed examples of transactions. Start off with basic examples and work up to more complex ones. Make extensive use of diagrams: step-by-step labeled block diagrams, waveforms, and/or network timing diagrams are all helpful.

12. Performance
Define high-level requirements for the performance of this block, and break them down into detailed first-order and second-order considerations. First-order: steady-state throughputs and unloaded latencies. Second-order: transient (burst/peak) throughputs and loaded latencies. Provide helpful example scenarios of common cases and edge/corner cases.

12.1. First-Order
These are the key "rules of thumb" to know about the block’s common-case performance. They can be divided into steady-state throughput and unloaded latency characteristics. These requirements should be well understood before any second-order requirements are considered.

12.1.1. Steady-State Throughput
Define the steady-state throughput requirements for the block and any assumptions about the clock frequencies needed to satisfy them. Steady-state throughput means the average bandwidth attained during a sufficiently long window of time where there are no "warm-up" or "cool-down" effects, and where the external system is not the bottleneck. Note that different interfaces are likely to have different throughputs, and they may also be coupled to each other.

12.1.2. Unloaded Latency
Define the unloaded latency requirements for the block and any assumptions about the clock frequencies needed to satisfy them. Unloaded latency means the minimum response time for the block to produce some output in response to an input stimulus when the block is initially idle. (This is sometimes known as structural latency or internal wire delay.) Note that unloaded latencies typically involve more than one interface, so be sure to cover the relevant combinations.

12.2. Second-Order
These are the things to know about the block’s edge-case or corner-case performance. They can be divided into transient hroughput and loaded latency, and arbitration/fairness/QoS.

12.2.1. Transient Throughput
The transient throughput (a.k.a. peak or burst) is the maximum bandwidth that can be achieved across an interface during a small window of time. Transient characteristics can have important effects in larger systems, so it is important for this to be explicitly specified. For instance, an input interface may support a transient throughput of 1 transaction per cycle in a window of up to 16 cycles, but its steady-state throughput may only be 0.5 transactions per cycle because of a downstream bottleneck. The difference between steady-state and transient throughput can typically be attributed to buffers within the design.

12.2.2. Loaded Latency
The loaded latency is the total response time for an individual transaction when initiated in the presence of other transactions. As a design experiences more transaction throughput, queuing theory tells us that the loaded latency will increase and is often unbounded. Like the unloaded latency, it typically involves a combination of interfaces. State your assumptions about the probability distribution of transaction arrival times and define the latency at specific percentiles (median, 95th, and 99th are common).

13. Arbitration, Fairness, and QoS
If the design involves multiple traffic classes or concurrent transaction types that can share any resources or interfaces, then their fairness properties should be defined. For example, if there are two independent traffic flows that arbitrate for an output interface, then the spec should clearly define the arbitration policy and the expected impacts on steady-state throughput and loaded latency as seen by each flow (e.g., from head-of-line blocking). Discuss any configurability features the design may have to control the arbitration policy or to achieve a different quality-of-service (QoS). If the design is unfair to any traffic class, state this explicitly. Ensure that any unfairness does not invalidate the forward progress guarantees (see below).

14. Forward Progress Guarantees
The design should guarantee forward progress, i.e., ensure that deadlock and livelock cannot occur. State any assumptions about the external system that are needed to satisfy these guarantees. Ideally, outline a proof for the forward progress guarantees that could potentially be formally verified.

15. Power
Define the relevant power requirements for the block under idle, peak, and steady-state conditions. If there are multiple power modes (e.g., dynamic voltage/frequency scaling or sleep modes), discuss how the block supports them. Define any fine-grain self-clock gating requirements (e.g., the proportion of flops that are automatically gated when idle or in typical operation).

16. Physical Design
The block microarchitecture design and physical design are tightly coupled. Include a sketch of the intended floorplan. It should be drawn roughly to scale and indicate the orientation. Show where the major interface pins and major SRAMs are placed. If the design uses a structured datapath with manual placements, track reservations, or metal layer reservations, describe those details as needed. Include a table of SRAM configurations. Summarize useful statistics about the block (estimated flop count, standard cell count, and critical path). If physical design data is available (e.g., later in a project), show a screenshot of the block post-placement and highlight the placement of major logic clouds that correspond to major submodules.

17. CSRs
List major categories of configuration/status registers (CSRs). Ideally, link to CSR documentation that is auto-generated from a single-source-of-truth source code. If infeasible, define all CSRs here instead. Every CSR should define its name, address, fields and offsets, hardware and software access permissions, and a description of what each field does.

18. Performance Analysis
Describe any features that the block has for performance analysis. For example, instrumentation counters and/or trace networks.

19. Debugging
Describe any non-mission-mode features that are meant to only be used for debugging the design post-silicon. This could include support for on-chip logic analyzers or JTAG.

20. Reliability
Chips are prone to failures. State the design’s relevant reliability requirements and describe any relevant features. Examples may include memory ECC, design-for-test/BIST circuits, timing monitors, etc.

21. Implementation Details
The remainder of the spec should show the design detail of every significant submodule. This section may often comprise 50% of the entire document. Organize the diagrams such that they correspond 1:1 with the RTL. Ideally, hyperlink diagrams to each other in a tree structure, thus allowing you to avoid overwhelming the reader with excessive details in any particular diagram and making it easy for the reader to correspond their knowledge of the design with the RTL code organization. For complex submodules, describe their implementations. Make note of any standard libraries or IPs and link to their specifications.

22. References
Link to other related documents — test plans, physical design information, source code location, protocol documents, chip-level specifications, etc.

