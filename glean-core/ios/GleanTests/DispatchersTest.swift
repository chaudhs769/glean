//
//  DispatchersTest.swift
//  GleanTests
//
//  Created by Travis Long on 9/12/19.
//  Copyright © 2019 Jan-Erik Rediger. All rights reserved.
//

@testable import Glean
import XCTest

class DispatchersTest: XCTestCase {
    func testTaskQueuing() {
        var threadCanary = 0

        Dispatchers.shared.setTestingMode(enabled: true)
        Dispatchers.shared.setTaskQueuing(enabled: true)

        // Add 3 tasks to the queue, each one incrementing threadCanary to indicate the task has executed
        for _ in 0 ..< 3 {
            Dispatchers.shared.launch {
                threadCanary += 1
            }
        }

        XCTAssertEqual(
            Dispatchers.shared.preInitOperations.count,
            3,
            "Task queue contains the correct number of tasks"
        )
        XCTAssertEqual(
            threadCanary,
            0,
            "Tasks have not executed while in queue"
        )

        // Now trigger the queue to fire the tasks
        Dispatchers.shared.flushQueuedInitialTasks()

        XCTAssertEqual(
            threadCanary,
            3,
            "Tasks have executed"
        )
        XCTAssertEqual(
            Dispatchers.shared.preInitOperations.count,
            0,
            "Task queue has cleared"
        )
    }

    func testQueuedTasksAreExecutedInOrder() {
        // Create a test operation queue to run our operations asynchronously
        let testQueue = OperationQueue()
        testQueue.name = "Glean test queue"
        // Set to 2 to allow both of our tasks to run concurrently
        testQueue.maxConcurrentOperationCount = 2

        var orderedList = [Int]()
        var flushTasks = AtomicBoolean(false)

        Dispatchers.shared.setTestingMode(enabled: false)
        Dispatchers.shared.setTaskQueuing(enabled: true)

        // This background task will monitor the size of the cached initial
        // operations and attempt to flush it when it reaches 50 elements.
        // This should give us 50 items in the queued items and 50 that are
        // executed in the background normally.
        let op1 = BlockOperation {
            while !flushTasks.value { sleep(1) }
            Dispatchers.shared.flushQueuedInitialTasks()
        }
        testQueue.addOperation(op1)

        // This background task will add elements to the orderedList.  This will continue to
        // add elements to the queue until there are at least 50 elements in the queue. At that
        // point, the background task above will flush and disable the queuing and this task will
        // continue launching tasks directly.
        var counter = 0
        let op2 = BlockOperation {
            for num in 0 ... 99 {
                if num == 50 {
                    flushTasks.value = true
                }
                _ = Dispatchers.shared.launch {
                    orderedList.append(num)
                    counter += 1
                }
            }
        }
        testQueue.addOperation(op2)

        // Wait for the numbers to be added to the list by waiting for the operations above to complete
        op1.waitUntilFinished()
        op2.waitUntilFinished()

        // Wait for all of the elements to be added to the list before we check the ordering
        while counter < 100 { sleep(1) }

        // Make sure the elements match in the correct order
        for num in 0 ... 99 {
            XCTAssertEqual(
                num,
                orderedList[num],
                "This list is out of order, \(num) != \(orderedList[num])"
            )
        }
    }

    func testCancelBackgroundTasksClearsQueuedItems() {
        // Set testing mode to false to allow for background execution
        Dispatchers.shared.setTestingMode(enabled: false)

        // Set task queueing to true to ensure that we queue tasks when we launch them
        Dispatchers.shared.setTaskQueuing(enabled: true)

        // Add a task to the pre-init queue
        Dispatchers.shared.launch {
            print("A queued task")
        }

        // Assert the task was queued
        XCTAssertEqual(Dispatchers.shared.preInitOperations.count, 1, "Task must be queued")

        // Now cancel the tasks, which will also clear the queued initial tasks
        Dispatchers.shared.cancelBackgroundTasks()

        // Assert the task was removed from the queue
        XCTAssertEqual(Dispatchers.shared.preInitOperations.count, 0, "Task must be removed")
    }
    
    func testCancelBackgroundTasksSerialQueue() {
        // Set testing mode to false to allow for background execution
        Dispatchers.shared.setTestingMode(enabled: false)
        
        // Set up our test conditions for normal execution by setting queuing to false
        Dispatchers.shared.setTaskQueuing(enabled: false)
        
        // Create a counter to use to determine if the task is actually cancelled
        var counter = 0
        
        // Create a task to add to the Dispatchers serial queue that looks at the
        // `isCancelled` property so that it can be cancelled
        let serialOperation = BlockOperation()
        serialOperation.addExecutionBlock {
            while !serialOperation.isCancelled {
                counter += 1
            }
        }
        Dispatchers.shared.serialOperationQueue.addOperation(serialOperation)
        
        // Let the task run for 1 second in order to it time to accumulate to the counter
        sleep(1)
        
        // Check that the counter has incremented
        XCTAssertTrue(counter > 0, "Serial task must execute")
        
        // Now cancel the background task
        Dispatchers.shared.cancelBackgroundTasks()
        
        // Wait for the task to be cancelled/finished, the OperationQueue will set
        // `isFinished` for cancelled tasks
        Dispatchers.shared.serialOperationQueue.waitUntilAllOperationsAreFinished()
        
        // Grab the current counter value. This shouldn't change after the task was cancelled
        let testValue = counter
        
        // Wait for one second to ensure task is truly cancelled. This gives the background task
        // time to continue to run and accumulate to the counter in the case that it wasn't
        // actually cancelled, that way we can detect the failure to cancel by comparing to the
        // snapshot of the counter value we just captured.
        sleep(1)
        
        // Make sure counters haven't changed
        XCTAssertEqual(counter, testValue, "Serial task must be cancelled")
    }
    
    func testCancelBackgroundTasksClearsConcurrentQueue() {
        // Set testing mode to false to allow for background execution
        Dispatchers.shared.setTestingMode(enabled: false)
        
        // Set up our test conditions for normal execution by setting queuing to false
        Dispatchers.shared.setTaskQueuing(enabled: false)
        
        // Create a counter to use to determine if the task is actually cancelled
        var counter = 0
        
        // Create a task to add to the concurrently executed queue that looks at the
        // `isCancelled` property so that it can be cancelled
        let concurrentOperation = BlockOperation()
        concurrentOperation.addExecutionBlock {
            while !concurrentOperation.isCancelled {
                counter += 1
            }
        }
        Dispatchers.shared.launchAsync(operation: concurrentOperation)
        
        // Let the task run for 1 second in order to give it time accumulate to the counter
        sleep(1)
        
        // Check that the counter has incremented
        XCTAssertTrue(counter > 0, "Concurrent task must execute")
        
        // Now cancel the background tasks
        Dispatchers.shared.cancelBackgroundTasks()
        
        // Wait for the task to be cancelled/finished, the OperationQueue will set
        // `isFinished` for cancelled tasks
        Dispatchers.shared.concurrentOperationsQueue.waitUntilAllOperationsAreFinished()
        
        // Grab the current counter value. This shouldn't change after the task is cancelled
        let asyncTest = counter
        
        // Wait for one second to ensure task is truly cancelled. This gives the background task
        // time to continue to run and accumulate to the counter in the case that it wasn't
        // actually cancelled, that way we can detect the failure to cancel by comparing to the
        // snapshot of the counter value we just captured.
        sleep(1)
        
        // Make sure counter hasn't changed
        XCTAssertEqual(counter, asyncTest, "Concurrent task must be cancelled")
    }
}