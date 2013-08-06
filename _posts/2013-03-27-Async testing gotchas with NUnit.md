--- 
layout: post
title: "Async Controller testing gotchas with NUnit"
comments: true
tags:
- .net
- nunit
---

NUnit released version 2.6.2 with support for testing asynchronous methods. I decided to give it a shot.

And my trial was to write some tests for an async WebApi controller. Lets say we have a controller called `UserController`. And I want to add an action called `Get` which looks like this - 

    public Task<User> Get(string userId)
    {
            if (string.IsNullOrEmpty(userId))
            {
                throw new ArgumentException("No username specified.");
            }
    
            return Task.Factory.StartNew(
                () =>
                    {
                        var user = userRepository.GetById(userId);
                        if (user != null)
                        {
                            return user;
                        }
    
                        throw new HttpResponseException(Request.CreateErrorResponse(
                        	HttpStatusCode.NotFound, string.Format("{0} - username does not exist", userId)));
                    });
    }
    
Great, so we have an action that is asynchronous. Now there are two kinds of tests that we would have to write, one for the happy path, and another to ensure that the exception is thrown with the right properties set.

Here's how I ended up writing the happy path test -

    [Test]
    public async void ShouldGetUserDetails()
    {
        var mockUserRepository = new Mock<IUserRepository>();
        mockUserRepository.Setup(x => x.GetByUserName(It.IsAny<string>())).Returns(new User { UserName = "foo" });
        var userController = new UserController(mockUserRepository.Object);

        var user = await userController.Get("foo");

        Assert.IsNotNull(user);
        Assert.That(user.UserName, Is.EqualTo("foo"));
    }

All good! The test passes. The only difference here is the use of `async` and `await` keywords in the test.

Now comes the fun part, I tried writing tests to assert on the exception part. It took some effort and [guidance on StackOverflow](http://stackoverflow.com/questions/15634542/nunit-async-test-exception-assertion) to figure out a way. The question has some examples of tests that I expected to work, but didn't.

The question also lists out various scenarios where my attempts to write a test to assert the exception thrown wasn't working as expected. There are explanations in the accepted answer.

Following the hint from the answer, I ended up writing a helper method that will help assert the exception thrown, along with specific properties to verify. Here is how I did it -

    public static class AssertEx
    {
        public static async Task ThrowsAsync<TException>(Func<Task> func) where TException : class
        {
            await ThrowsAsync<TException>(func, exception => { });
        } 
    
        public static async Task ThrowsAsync<TException>(Func<Task> func, Action<TException> action) where TException : class
        {
            var exception = default(TException);
            var expected = typeof(TException);
            Type actual = null;
            try
            {
                await func();
            }
            catch (Exception e)
            {
                exception = e as TException;
                actual = e.GetType();
            }
    
            Assert.AreEqual(expected, actual);
            action(exception);
        }
    }
    
And this is how I use it

    [Test]
    public async void ShouldThrow404WhenNotFound()
    {
        var mockUserRepository = new Mock<IUserRepository>();
        mockUserRepository.Setup(x => x.GetByUserName(It.IsAny<string>())).Returns(default(User));
        var userController = new UserController(mockUserRepository.Object) { Request = new HttpRequestMessage() };

        Action<HttpResponseException> asserts = exception => Assert.That(exception.Response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        await AssertEx.ThrowsAsync(() => userController.Get("foo"), asserts);
    }
    
Note that the asserts are now wrapped into an action and passed to `AssertEx.ThrowsAsync`.