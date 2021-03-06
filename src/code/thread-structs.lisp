;;;; support for threads needed at cross-compile time

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-THREAD")

;;; N.B.: If you alter this definition, then you need to verify that FOP-FUNCALL
;;; in genesis can properly emulate MAKE-MUTEX for the altered structure,
;;; or even better, make sure that genesis can emulate any constructor,
;;; provided that it is sufficiently trivial.
(sb-xc:defstruct (mutex (:constructor make-mutex (&key name))
                        (:copier nil))
  "Mutex type."
  ;; C code could (but doesn't currently) access the name
  #+(and sb-thread sb-futex)
  (state    0 :type fixnum)
  ;; If adding slots between STATE and NAME, please see futex_name() in linux_os.c
  ;; which attempts to divine a string from a futex word address.
  (name   nil :type (or null simple-string))
  (%owner nil :type (or null thread)))

#+(or (not sb-thread) sb-futex)
(sb-xc:defstruct (waitqueue (:copier nil) (:constructor make-waitqueue (&key name)))
  "Waitqueue type."
  #+(and sb-thread sb-futex)
  (token 0
         ;; actually 32-bits, but it needs to be a raw slot and we don't have
         ;; 32-bit raw slots on 64-bit machines.
         #+futex-use-tid :type #+futex-use-tid sb-ext:word)
  ;; If adding slots between TOKEN and NAME, please see futex_name() in linux_os.c
  ;; which attempts to divine a string from a futex word address.
  (name nil :type (or null string)))

#+(and sb-thread (not sb-futex))
(sb-xc:defstruct (waitqueue (:copier nil) (:constructor make-waitqueue (&key name)))
  "Waitqueue type."
  (name nil :type (or null string))
  ;; For WITH-CAS-LOCK: because CONDITION-WAIT must be able to call
  ;; %WAITQUEUE-WAKEUP without re-aquiring the mutex, we need a separate
  ;; lock. In most cases this should be uncontested thanks to the mutex --
  ;; the only case where that might not be true is when CONDITION-WAIT
  ;; unwinds and %WAITQUEUE-DROP is called.
  %owner
  %head
  %tail)

(sb-xc:defstruct (semaphore (:copier nil)
                            (:constructor %make-semaphore (%count mutex queue)))
  "Semaphore type. The fact that a SEMAPHORE is a STRUCTURE-OBJECT
should be considered an implementation detail, and may change in the
future."
  (%count    0 :type (integer 0))
  (waitcount 0 :type sb-vm:word)
  (mutex nil :read-only t :type mutex)
  (queue nil :read-only t :type waitqueue))

(declaim (sb-ext:freeze-type waitqueue semaphore))

(sb-xc:defstruct (thread (:constructor %make-thread (name %ephemeral-p semaphore))
                         (:copier nil))
  "Thread type. Do not rely on threads being structs as it may change
in future versions."
  (name          nil :type (or null simple-string)) ; C code could read this
  (%ephemeral-p  nil :type boolean :read-only t)
  ;; This is one of a few different views of a lisp thread:
  ;;  1. the memory space (thread->os_addr in C)
  ;;  2. 'struct thread' at some offset into the memory space, coinciding
  ;;     with the SB-VM::THREAD primitive object
  ;;  3. a pthread, which may reside anywhere, possibly the high end of the lisp stack
  ;;     (above the SP given to your entrypoint), whatever the pthread library chooses.
  ;;  4. the THREAD instance (this structure)
  ;; This value is 0 if the thread is not considered alive, though the pthread
  ;; may be running its termination code (unlinking from all_threads etc)
  (primitive-thread 0 :type sb-vm:word)
  ;; This is a redundant copy of the pthread identifier from the primitive thread.
  ;; It's needed in the SB-THREAD:THREAD as well because there are valid reasons to
  ;; manipulate the new thread before it has assigned 'th->os_thread = pthread_self()'.
  ;; While we always have access to the C struct thread from Lisp, apparently the C
  ;; code can't pass "&th->os_thread" as the first argument to pthread_create() for the
  ;; incredible reason that the word might be written *after* the memory pointed at
  ;; by 'th' has already been freed. Such action might seem to violate:
  ;;  "Before returning, a successful call to pthread_create() stores the ID of the
  ;;   new thread in the buffer pointed to by thread"
  ;;  (https://man7.org/linux/man-pages/man3/pthread_create.3.html)
  ;; but that's not exactly what POSIX says, which is only:
  ;;  "Upon successful completion, pthread_create() stores the ID of the created thread
  ;;   in the location referenced by thread."
  ;; (https://pubs.opengroup.org/onlinepubs/007908799/xsh/pthread_create.html)
  ;; so there seems to be some leeway, and linux + glibc provides more of a guarantee.
  ;; Technically we should have only one authoritative source of the pthread identifier,
  ;; but it's not too critical, it's just annoying that there are two sources of
  ;; the same value.
  ;; The slot is somewhat poorly named (for consistency with C) because though it may
  ;; correspond to an OS thread, it could be the case that the threading model has
  ;; user-visible threads that do not map directly to OSs threads (or LWPs).
  ;; Any use of THREAD-OS-THREAD from lisp should take care to ensure validity of
  ;; the thread id by holding the INTERRUPTIONS-LOCK.
  (os-thread 0 :type sb-vm:word)
  ;; Keep a copy of CONTROL-STACK-END from the "primitive" thread.
  ;; Reading that memory for any thread except *CURRENT-THREAD* is not safe
  ;; due to possible unmapping on thread death.
  ;; Usually this is a fixed amount below PRIMITIVE-THREAD, but the exact offset
  ;; varies by build configuration, and if #+win32 it is not related in any way.
  (stack-end 0 :type sb-vm:word)
  ;; At the beginning of the thread's life, this is a vector of data required
  ;; to start the user code. At the end, is it pointer to the 'struct thread'
  ;; so that it can be either freed or reused.
  (startup-info 0 :type (or fixnum (simple-vector 6)))
  ;; Whether this thread should be returned in LIST-ALL-THREADS.
  ;; This is almost-but-not-quite the same as what formerly
  ;; might have been known as the %ALIVE-P flag.
  (%visible 1 :type fixnum)
  (interruptions nil :type list)
  (interruptions-lock
   (make-mutex :name "thread interruptions lock")
   :type mutex :read-only t)
  ;; On succesful execution of the thread's lambda, a list of values.
  (result 0)
  (semaphore nil :type (or null semaphore))
  waiting-for)

(sb-xc:defstruct (foreign-thread
                  (:copier nil)
                  (:include thread (name "callback"))
                  (:constructor make-foreign-thread ())
                  (:conc-name "THREAD-"))
  "Type of native threads which are attached to the runtime as Lisp threads
temporarily.")

#+(and sb-safepoint-strictly (not win32))
(sb-xc:defstruct (signal-handling-thread
                  (:copier nil)
                  (:include foreign-thread)
                  (:conc-name "THREAD-"))
  "Asynchronous signal handling thread."
  (signal-number nil :type integer))

(declaim (sb-ext:freeze-type mutex thread))
