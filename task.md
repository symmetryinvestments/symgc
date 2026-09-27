You are in the repository of new GC for D language.

Currently this GC implementation is not supporting macOS arm. And your task would be to implement it.

It has some tests. You will need to implement the GC for macOS ARM (M1 chip family) and make all tests working.
But you can't change any code in test folder.

You may need some codes for threads. On macOS you may use kqueue.
For your convenience, I've added several projects (libasync and eventcore) which has macOS threads support.
They are located in the folder `threads_examples`. You may use it to see how version for macOS could be implemented.

Try to use the same patterns and approachs and code style and design as already implemented in the symgc project for Windows and Linux.
