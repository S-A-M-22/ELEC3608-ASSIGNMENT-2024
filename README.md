## Assignment - RV32IM Single Cycle Processor
#### Goals
- Use the knowledge gained from earlier labs to implement a single-cycle RV32I processor with 'M' extensions.
- Gain experience writing technical reports.
In the labs for this course, you have developed a series of RV32I processors culminating in a simple pipelined processor. In this assignment, you will extend the microarchitecture to design and test a complete RV32IM processor.

#### Question
Starting with the complete single cycle processor that you developed in the labs, add the M extensions, i.e. create a single-cycle RV32IM processor. The M Extensions are described in Section 13 of Volume 1, Unprivileged Specification version 20240411 https://riscv.org/technical/specifications/.

### (5 marks) Part 1: Implementation.
Develop a complete single cycle RV32IM processor using nerv.sv in this directory as a starting point. This question will be machine marked based on correctness (execution time is not considered). We will run your processor using the make result target as explained below with that are not provided to you. Note that a straightforwad implementation will use more than 100% of the FPGA (the largest Lattice iCE40 device). If your design does not completely fit in the FPGA, the maximum mark is 70%. The additional 30% is left for optimising the design to fit entirely on the FPGA.

The sample test programs provided in this directory don't have instructions from the M extensions. It is your job to create your own test programs to verify your RV32IM meets the full specification. If you find mistakes in the starting RV32I processor, these should be fixed and noted in your report (you will receive extra credit). Modify the Makefile somake result runs all your tests (this may be used to evaluate your work if you don't pass all my tests).

```
$ make result
...
Test summary
period: 2.701242571582928e-08
test1.result: x10=55 cycles=18 extime=4.86223662884927e-07 normextime=1.0
test2.result: x10=3790353928 cycles=15 extime=4.051863857374392e-07 normextime=1.0
test3.result: x10=45 cycles=40 extime=1.0804970286331712e-06 normextime=1.0
test4.result: x10=210 cycles=130 extime=3.5116153430578064e-06 normextime=1.0
test5.result: x10=21 cycles=942 extime=2.5445705024311184e-05 normextime=1.0
Geometric mean=1.0
```
The output gives the minimum clock period (period), value of the x10 register (x10), the number of cycles (cycles), execution time (extime), execution time normalised to the original design (normextime), and the gemetric mean of normextime. The geometric mean is the mean speedup over the nerv single cycle processor (note that it is used because it is the only correct mean when averaging normalized results see https://en.wikipedia.org/wiki/Geometric_mean). We will not be running any of these tests in machine marking (and hence not use the normalized execution time or mean), they are just used as examples of how to create a test suite.

### (5 marks) Part 2: Report.
- Your report should be a document with maximum of 6 pages explaining your design (appendices with no page limit can be included).
- The report should be in [A4 IEEE format](https://www.ieee.org/conferences/publishing/templates.html) with the default font sizes, and organized under the following section headings: Introduction, Background, Architecture, Results, Discussion, Conclusion, References, Appendices.
This page provides a link to guides on writing reports https://phwl.org/resources.
- It should include a full datapath description and matching control table like that given in the "Hardwired Control Table (Excerpt)" slide in Lecture 4 Single Cycle Processor.
- Create a table of your test programs and explain their functionality in your report. Also explain how they provide good coverage of the 'M' extensions, what is the correct x10 result and why.
- Include a performance description which includes maximum clock frequency of your processor and number of cycles required to execute each program you test. You need to provide supporting evidence which can convince the reader that you have completed the design and it works via appendices containing code listings, simulations and log files. The appendices don't count in the page limit.
- [Dennis et al.](https://ieeexplore.ieee.org/abstract/document/8303926) and [Miyazaki et al.](https://arxiv.org/abs/2002.03568) are two examples of well-written papers describing a RISC-V processor (you could following a similar style for your report). [Singh et al.](https://ieeexplore.ieee.org/document/9250850) is an example of a poorly written paper.
- You should assume that the reader is familiar computer architecture in general, but not necessarily the the RISC-V instruction set or your architecture. Write the report as an academic-style paper like the examples provided.


## Assignment - Multi-Core Processor
#### Goals
- Use the knowledge gained from earlier labs to implement two complete pipelined RV32IA processors which can run separate programs on a shared memory.
- Gain experience writing technical reports.
In the labs for this course, you have sucecssively built up capability for the RV32I instruction set. Now you will extend this to a multicore processor network, where two instances of your processor will coexist on the same silicon. We make use of the lr.w and sc.w atomic instructions, and a special memory.

See the background section below for more theory.

Note: You will not need to synthesize this design onto an FPGA. Simulation is sufficient for this assignment

### Question
Create a pipelined RV32IA processor which implements enough of the instructions specified in Volume 1 Sections 2.1-2.6 of the RISC-V ISA Specification https://riscv.org/technical/specifications/ to execute the programs supplied with this assignment and add the following features (with each improvement including the functionality from previous part):

  1. (2 marks) Add the Atomic series "A" series instructions for the extension Zalrsc, as described in Section 13.2 of the specification. Only these two instructions need be implemented: Load reservation: lr.w, and Store conditional: sc.w
     - You may submit a single-cycle version for reduced credit (1 mark maximum)
  
  3. (1 mark) Modify the RAM memory module to support two write accesses and two read accesses concurrently. This should be placed into your processor .sv file, not the testbench file. Decide on a priority scheme when both attempt to write in the same cycle, and document it in your report.

  4. (2 marks) Add a reservation vector for each core, where the appropriate reservation (based on the address) is set for that core when the lr.w instruction is executed, all reservations for that address are cleared when a sc.w instruction is set, and the appropriate status code is returned to the calling core. Document the dataflow path, and describe how you handle pipeline issues.

  5. (5 marks) Report (see below)

#### Test files
The machine marked parts will consider correctness and performance. Use the `make result FIRMWARE=test_filename.hex` to test a single result, and use make allresults to run the whole test suite.

```
---------------------------------------------------
Results...
cat results.log
Source file: test1-hart1-only.s    Sim file: test1-hart1-only.log
Total failures = 0 of 3 tests

Source file: test2-hart2-only.s    Sim file: test2-hart2-only.log
Total failures = 0 of 3 tests

Source file: test3-samecode-bothharts.s    Sim file: test3-samecode-bothharts.log
Total failures = 0 of 10 tests

Source file: test4-race-hart1-slowslow.s    Sim file: test4-race-hart1-slowslow.log
Total failures = 0 of 9 tests

Source file: test5-race-hart2-slowslow.s    Sim file: test5-race-hart2-slowslow.log
Total failures = 0 of 9 tests

Source file: test6-race-hart1-slow.s    Sim file: test6-race-hart1-slow.log
  h0:x2 expected 193  got  192
  h0:x5 expected 1  got  0
  h0:x6 expected 193  got  192
  h1:x6 expected 193  got  0
Total failures = 4 of 9 tests
```

### Reports
- Your report should be a 4 page document explaining your design (appendices with no page limit can be included).
- Your report should be in [A4 IEEE format](https://www.ieee.org/conferences/publishing/templates.html) with the default font sizes, and organized under the following section headings: Introduction, Background, Architecture, Results, Discussion, Conclusion, References, Appendices.
- Your report should document the datapath design of all the major components, including a high-level description and/or diagram, and specific implementation of the major subsystems. This is a narrative description to as given to a fellow engineer, and not merely a copy of code.
- Include a performance description which includes number of cycles required to execute each program you test. You need to provide supporting evidence which can convince the reader that you have completed the design and it works via appendices containing code listings, simulations and log files. The appendices don't count in the page limit.
- Comment on whether your result is a good one and what could be done to further improve performance.
- [Dennis et al.](https://ieeexplore.ieee.org/abstract/document/8303926) and [Miyazaki et al.](https://arxiv.org/abs/2002.03568) are two examples of well-written papers describing a RISC-V processor (you could following a similar style for your report). [Singh et al.](https://ieeexplore.ieee.org/document/9250850) is an example of a poorly written paper.
- You should assume that the reader is familiar computer architecture in general, but not necessarily the the RISC-V instruction set or your architecture. Write the report as an academic-style paper like the examples provided.
