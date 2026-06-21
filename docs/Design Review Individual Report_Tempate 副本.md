# Design Review Individual Report

1. What specific components or tasks have you been responsible for so far?

I have mainly worked on the next-line prefetching part of the cache and on testbench-related verification work in Vivado. I also helped with project documentation.

2. What progress have you made on your assigned tasks, including writing the thesis?

The basic next-line prefetching mechanism has been integrated into the project baseline, and the verification environment is in place for simulation and functional checking. On the writing side, I contributed to the team report and other project documents for Design Review I.

3. What challenges or blockers have you encountered? How did you attempt to solve them?

One difficulty is that much of the cache control logic is concentrated in a single `always_ff` block, which makes debugging and incremental improvement harder. To address this, I first relied on simulation and testbench checks to isolate behavior, and I plan to further separate the logic into clearer modules in the next stage.

4. How have you collaborated with other team members?

I communicated with teammates through Feishu and GitHub, discussed implementation details, and coordinated documentation and verification work so our code and reports stayed consistent.

5. What are your goals for the next stage of the project?

My next goals are to improve and evaluate the next-line prefetching module, strengthen the Vivado testbench and test cases, and help complete the remaining verification and documentation work.
