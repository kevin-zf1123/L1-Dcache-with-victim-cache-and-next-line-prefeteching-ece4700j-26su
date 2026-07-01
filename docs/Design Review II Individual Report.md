# Design Review II Individual Report

## 1. What specific components or tasks have you been responsible for so far?

My main responsibility so far has been the pollution monitor and related cache statistics path. This includes thinking about how to measure the effect of next-line prefetching more meaningfully, tracking prefetch-related events in the cache, and helping make sure the statistics are useful for later workload comparison rather than only for basic debugging.

I have also contributed to testbench-related work and report preparation. In practice, that means helping connect the monitoring logic to verification, reviewing whether the generated statistics match expected workload behavior, and supporting the writing and revision of Design Review materials so the documentation reflects the implemented cache more accurately.

## 2. What progress have you made on your assigned tasks, including writing the thesis?

I have made clear progress on the monitoring side of the project. The cache now records prefetch-related statistics such as useful prefetches, useless prefetches, pollution-related events, and dropped prefetch candidates, and these counters are already visible in the simulation results. This gives the project a stronger basis for analyzing when prefetching helps and when it harms performance. I also helped review the existing regression outputs, including synthetic workloads and trace replay results, to make sure the monitoring data can be interpreted together with hits, misses, memory reads, and cycle counts.

For writing, I have contributed to the Design Review II documentation by helping rewrite the report so that it matches the current repository state and measured results. The current materials now describe the implemented blocking L1 data cache, the victim cache, the next-line prefetching behavior, and the current evaluation flow more consistently. Some thesis writing is still in progress, especially the parts that need deeper analysis of workload results and stronger interpretation of the monitoring data.

## 3. What challenges or blockers have you encountered? How did you attempt to solve them?

One challenge was that prefetch pollution is not easy to measure correctly. A simple displacement counter can overstate the harm of prefetching, because a line evicted by a prefetched line may still be rescued later by the victim cache. To deal with this, I focused on improving the monitoring interpretation and checking the counter behavior against real workload outcomes such as misses, victim hits, memory traffic, and total cycles instead of treating one counter as a final answer.

Another challenge was that some repository documents did not fully match the live source tree and current simulation evidence. That made it harder to write a precise review report. I addressed this by treating the active RTL files, regression scripts, and generated logs as the most reliable sources, then using those artifacts to revise the report text so the written review stays aligned with the actual implementation status.

## 4. How have you collaborated with other team members?

I collaborated with my teammates mainly through discussion of task scope, monitoring goals, and how to interpret intermediate results. We used those discussions to decide what statistics were worth keeping, how the monitoring work should connect to the cache behavior, and which results were strong enough to include in the review materials.

I also supported integration work by checking that the monitoring and testbench outputs were useful for the broader team, not only for my own part. This included helping connect implementation progress with documentation, sharing observations from workload results, and contributing to a more consistent explanation of what has already been completed and what still remains for the next stage.

## 5. What are your goals for the next stage of the project?

My main goal for the next stage is to continue improving the statistics and monitoring path so that the final evaluation can say more than just whether hit rate changed. I want to help refine how we study prefetch usefulness, pollution, and memory-traffic overhead, and to connect those measurements more clearly to workload behavior and cycle-level performance.

I also plan to keep advancing the testbench and evaluation flow. That includes supporting more workload-driven experiments, checking that the reported counters remain trustworthy across different configurations, and contributing to the final thesis writing so the monitoring-related results are clearly explained and properly supported by evidence.
