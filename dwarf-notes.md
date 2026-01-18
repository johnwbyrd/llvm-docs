Things that make MOS DWARF hard:

- DWARF is essentially a Turing-complete, stack based machine that lets you evaluate any expression across registers, memory, and system state.  
- DWARF exists to help you know where your variables and stack frames are.  It also helps with function backtracing.
- In order to express details about your program in DWARF, you have to write code for this tiny stack-based machine, to be run by your debugger at debug time.
- There are two stacks.  DWARF can handle this and represent these conditions, but you have to design special expressions explicitly for both stacks
- On MOS platforms, zero is a valid program address.  Much of the lld machinery assumes that a zero address is invalid, and stamps it on things that can be garbage collected.  We specifically need to walk around and manually pick up these pieces and throw them out, so they don't confuse the final MOS program.
