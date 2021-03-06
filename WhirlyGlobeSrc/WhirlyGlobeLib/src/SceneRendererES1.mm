/*
 *  SceneRendererES1.mm
 *  WhirlyGlobeLib
 *
 *  Created by Steve Gifford on 1/13/11.
 *  Copyright 2011 mousebird consulting
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import "SceneRendererES1.h"
#import "UIColor+Stuff.h"

using namespace WhirlyKit;

namespace WhirlyKit
{
PerformanceTimer::TimeEntry::TimeEntry()
{
    name = "";
    minDur = MAXFLOAT;
    maxDur = 0.0;
    avgDur = 0.0;
    numRuns = 0;
}
    
bool PerformanceTimer::TimeEntry::operator<(const WhirlyKit::PerformanceTimer::TimeEntry &that) const
{
    return name < that.name;
}
    
void PerformanceTimer::TimeEntry::addTime(NSTimeInterval dur)
{
    minDur = std::min(minDur,dur);
    maxDur = std::max(maxDur,dur);
    avgDur += dur;
    numRuns++;
}
    
PerformanceTimer::CountEntry::CountEntry()
{
    name = "";
    minCount = 1<<30;
    maxCount = 0;
    avgCount = 0;
    numRuns = 0;
}
    
bool PerformanceTimer::CountEntry::operator<(const WhirlyKit::PerformanceTimer::CountEntry &that) const
{
    return name < that.name;
}
    
void PerformanceTimer::CountEntry::addCount(int count)
{
    minCount = std::min(minCount,count);
    maxCount = std::max(maxCount,count);
    avgCount += count;
    numRuns++;
}
    
void PerformanceTimer::startTiming(const std::string &what)
{
    actives[what] = CFAbsoluteTimeGetCurrent();
}

void PerformanceTimer::stopTiming(const std::string &what)
{
    std::map<std::string,NSTimeInterval>::iterator it = actives.find(what);
    if (it == actives.end())
        return;
    NSTimeInterval start = it->second;
    actives.erase(it);
    
    std::map<std::string,TimeEntry>::iterator eit = timeEntries.find(what);
    if (eit != timeEntries.end())
        eit->second.addTime(CFAbsoluteTimeGetCurrent()-start);
    else {
        TimeEntry newEntry;
        newEntry.addTime(CFAbsoluteTimeGetCurrent()-start);
        newEntry.name = what;
        timeEntries[what] = newEntry;
    }
}
    
void PerformanceTimer::addCount(const std::string &what,int count)
{
    std::map<std::string,CountEntry>::iterator it = countEntries.find(what);
    if (it != countEntries.end())
        it->second.addCount(count);
    else {
        CountEntry newEntry;
        newEntry.addCount(count);
        newEntry.name = what;
        countEntries[what] = newEntry;
    }
}
    
void PerformanceTimer::clear()
{
    actives.clear();
    timeEntries.clear();
    countEntries.clear();
}

void PerformanceTimer::log()
{
    for (std::map<std::string,TimeEntry>::iterator it = timeEntries.begin();
         it != timeEntries.end(); ++it)
    {
        TimeEntry &entry = it->second;
        if (entry.numRuns > 0)
            NSLog(@"  %s: min, max, avg = (%.2f,%.2f,%.2f) ms",entry.name.c_str(),1000*entry.minDur,1000*entry.maxDur,1000*entry.avgDur / entry.numRuns);
    }
    for (std::map<std::string,CountEntry>::iterator it = countEntries.begin();
         it != countEntries.end(); ++it)
    {
        CountEntry &entry = it->second;
        if (entry.numRuns > 0)
            NSLog(@"  %s: min, max, avg = (%d,%d,%2.f) count",entry.name.c_str(),entry.minCount,entry.maxCount,(float)entry.avgCount / (float)entry.numRuns);
    }
}
    
}

@implementation WhirlyKitRendererFrameInfo

@synthesize sceneRenderer;
@synthesize theView;
@synthesize modelTrans;
@synthesize scene;
@synthesize frameLen;
@synthesize currentTime;
@synthesize eyeVec;

@end

// Alpha stuff goes at the end
// Otherwise sort by draw priority
class drawListSortStruct
{
public:
    // These methods are here to make the compiler shut up
    drawListSortStruct() { }
    ~drawListSortStruct() { }
    drawListSortStruct(const drawListSortStruct &that) {  }
    drawListSortStruct & operator = (const drawListSortStruct &that) { return *this; }
    bool operator()(const Drawable *a,const Drawable *b) 
    {
        if (a->hasAlpha(frameInfo) == b->hasAlpha(frameInfo))
            return a->getDrawPriority() < b->getDrawPriority();

        return !a->hasAlpha(frameInfo);
    }
    
    WhirlyKitRendererFrameInfo *frameInfo;
};

@interface WhirlyKitSceneRendererES1()
- (void)setupView;
@end

@implementation WhirlyKitSceneRendererES1

@synthesize context;
@synthesize scene,theView;
@synthesize zBuffer;
@synthesize framebufferWidth,framebufferHeight;
@synthesize scale;
@synthesize framesPerSec;
@synthesize perfInterval;
@synthesize numDrawables;
@synthesize delegate;

- (id <WhirlyKitESRenderer>) init
{
	if ((self = [super init]))
	{
		frameCount = 0;
		framesPerSec = 0.0;
        numDrawables = 0;
		frameCountStart = nil;
        zBuffer = true;
        clearColor.r = 0.0;  clearColor.g = 0.0;  clearColor.b = 0.0;  clearColor.a = 1.0;
        perfInterval = -1;
        scale = [[UIScreen mainScreen] scale];
		
		context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
        
        if (!context || ![EAGLContext setCurrentContext:context])
		{
            return nil;
        }

        // Create default framebuffer object.
        glGenFramebuffers(1, &defaultFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
        
        // Create color render buffer and allocate backing store.
        glGenRenderbuffers(1, &colorRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorRenderbuffer);

		// Allocate depth buffer
		glGenRenderbuffers(1, &depthRenderbuffer);
		glBindRenderbuffer(GL_RENDERBUFFER, depthRenderbuffer);
	}
	
	return self;
}

- (void) dealloc
{
	[EAGLContext setCurrentContext:context];
	
	if (defaultFramebuffer)
	{
		glDeleteFramebuffers(1, &defaultFramebuffer);
		defaultFramebuffer = 0;
	}
	
	if (colorRenderbuffer)
	{
		glDeleteRenderbuffers(1, &colorRenderbuffer);
		colorRenderbuffer = 0;
	}
	
	if (depthRenderbuffer)
	{
		glDeleteRenderbuffers(1, &depthRenderbuffer	);
		depthRenderbuffer = 0;
	}
	
	context = nil;
	
}

- (void)useContext
{
	if (context)
		[EAGLContext setCurrentContext:context];
}

- (BOOL) resizeFromLayer:(CAEAGLLayer *)layer
{	
    [EAGLContext setCurrentContext:context];

	glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
	[context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)layer];
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &framebufferWidth);
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &framebufferHeight);	

	// For this sample, we also need a depth buffer, so we'll create and attach one via another renderbuffer.
	glBindRenderbuffer(GL_RENDERBUFFER, depthRenderbuffer);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, framebufferWidth, framebufferHeight);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRenderbuffer);
	
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
	{
		NSLog(@"Failed to make complete framebuffer object %x", glCheckFramebufferStatus(GL_FRAMEBUFFER));		
		return NO;
	}
	
	[self setupView];
	
	return YES;
}

- (void) setClearColor:(UIColor *)color
{
    clearColor = [color asRGBAColor];
}

// Set up the various view parameters
- (void)setupView
{
    // If the client provided a setupView, use that
    if (delegate && [(NSObject *)delegate respondsToSelector:@selector(lightingSetup:)])
    {
        [delegate lightingSetup:self];
    } else {
        // Otherwise we'll do a default setup
        // If you make your own, just copy this to start
        const GLfloat			lightAmbient[] = {0.5, 0.5, 0.5, 1.0};
        const GLfloat			lightDiffuse[] = {0.6, 0.6, 0.6, 1.0};
        const GLfloat			matAmbient[] = {0.5, 0.5, 0.5, 1.0};
        const GLfloat			matDiffuse[] = {1.0, 1.0, 1.0, 1.0};	
        const GLfloat			matSpecular[] = {1.0, 1.0, 1.0, 1.0};
        const GLfloat			lightPosition[] = {0.75, 0.5, 1.0, 0.0}; 
        const GLfloat			lightShininess = 100.0;
        
        //Configure OpenGL lighting
        glEnable(GL_LIGHTING);
        glEnable(GL_LIGHT0);
        glMaterialfv(GL_FRONT_AND_BACK, GL_AMBIENT, matAmbient);
        glMaterialfv(GL_FRONT_AND_BACK, GL_DIFFUSE, matDiffuse);
        glMaterialfv(GL_FRONT_AND_BACK, GL_SPECULAR, matSpecular);
        glMaterialf(GL_FRONT_AND_BACK, GL_SHININESS, lightShininess);
        glLightfv(GL_LIGHT0, GL_AMBIENT, lightAmbient);
        glLightfv(GL_LIGHT0, GL_DIFFUSE, lightDiffuse);
        glLightfv(GL_LIGHT0, GL_POSITION, lightPosition); 
        glShadeModel(GL_SMOOTH);
        glEnable(GL_COLOR_MATERIAL);
    }

	// Set it back to model view
	glMatrixMode(GL_MODELVIEW);	
	glEnable(GL_BLEND);	
    
	// Set a blending function to use
	glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
}

// Utility function to calculate a reasonable Geo MBR for the viewport
- (GeoMbr) calcViewGeoMbr:(WhirlyGlobeView *)globeView frameSize:(Point2f)frameSize modelTrans:(Eigen::Affine3f *)modelTrans
{
    Point3f hits[8];
    GeoMbr viewGeoMbr;
    CGPoint pts[8];
    
    // Corner points
    pts[0] = CGPointMake(-frameSize.x()/4, -frameSize.y()/4);
    pts[1] = CGPointMake(1.25*frameSize.x(), -frameSize.y()/4);
    pts[2] = CGPointMake(1.25*frameSize.x(), 1.25*frameSize.y());
    pts[3] = CGPointMake(-frameSize.x()/4, 1.25*frameSize.y());
    // Add some mid points to catch the curvature
    for (unsigned int ii=0;ii<4;ii++)
    {
        CGPoint &p0 = pts[ii];
        CGPoint &p1 = pts[(ii+1)%4];
        CGPoint mid = CGPointMake((p0.x+p1.x)/2, (p0.y+p1.y)/2);
        pts[ii+4] = mid;
    }

    bool onSphere = true;
    for (unsigned int ii=0;ii<8;ii++)
    {
        if (![globeView pointOnSphereFromScreen:pts[ii] transform:modelTrans frameSize:frameSize hit:&hits[ii]])
        {
            onSphere = false;
            break;
        }
    }
    
    // If all those points where on the sphere, get us an MBR
    if (onSphere)
    {
        CoordSystem *coordSys = scene->coordSystem;
        for (unsigned int jj=0;jj<8;jj++)
        {
            GeoCoord coord = coordSys->localToGeographic(coordSys->geocentricishToLocal(hits[jj]));
            viewGeoMbr.addGeoCoord(coord);
        }        
    } else {
        // If we're sampling points outside the sphere, toss back the whole thing
        viewGeoMbr.ll() = GeoCoord::CoordFromDegrees(-180, -90);
        viewGeoMbr.ur() = GeoCoord::CoordFromDegrees(180, 90);
    }
    
    return viewGeoMbr;
}

- (void) render:(CFTimeInterval)duration
{  
    if (perfInterval > 0)
        perfTimer.startTiming("Render");

    CoordSystem *coordSys = scene->getCoordSystem();
    
	if (frameCountStart)
		frameCountStart = CFAbsoluteTimeGetCurrent();
	
    if (perfInterval > 0)
        perfTimer.startTiming("Render Setup");
	[theView animate];
	
    [EAGLContext setCurrentContext:context];
    
    glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
    glViewport(0, 0, framebufferWidth, framebufferHeight);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
	Point2f frustLL,frustUR;
	GLfloat near=0,far=0;
	[theView calcFrustumWidth:framebufferWidth height:framebufferHeight ll:frustLL ur:frustUR near:near far:far];
	glFrustumf(frustLL.x(),frustUR.x(),frustLL.y(),frustUR.y(),near,far);
	
	glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
	Eigen::Affine3f modelTrans = [theView calcModelMatrix];
	glLoadMatrixf(modelTrans.data());

    if (zBuffer)
    {
        glDepthMask(GL_TRUE);
        glEnable(GL_DEPTH_TEST);
    } else {
        glDepthMask(GL_FALSE);
        glDisable(GL_DEPTH_TEST);
    }

	glClearColor(clearColor.r, clearColor.g, clearColor.b, clearColor.a);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		
	glEnable(GL_CULL_FACE);
        
    // Call the pre-frame callback
    if (delegate && [(NSObject *)delegate respondsToSelector:@selector(preFrame:)])
        [delegate preFrame:self];
    
    if (perfInterval > 0)
        perfTimer.stopTiming("Render Setup");
    
	if (scene)
	{
		numDrawables = 0;
        
        WhirlyKitRendererFrameInfo *frameInfo = [[WhirlyKitRendererFrameInfo alloc] init];
        frameInfo.sceneRenderer = self;
        frameInfo.theView = theView;
        frameInfo.modelTrans = modelTrans;
        frameInfo.scene = scene;
        frameInfo.frameLen = duration;
        frameInfo.currentTime = CFAbsoluteTimeGetCurrent();
		
        if (perfInterval > 0)
            perfTimer.startTiming("Scene processing");

        if (perfInterval > 0)
            perfTimer.addCount("Scene changes", scene->changeRequests.size());
        
		// Merge any outstanding changes into the scenegraph
		// Or skip it if we don't acquire the lock
		// Note: Time this and move it elsewhere
		scene->processChanges(theView);
        
        if (perfInterval > 0)
            perfTimer.stopTiming("Scene processing");
        
        if (perfInterval > 0)
            perfTimer.startTiming("Culling");
		
		// We need a reverse of the eye vector in model space
		// We'll use this to determine what's pointed away
		Eigen::Matrix4f modelTransInv = modelTrans.inverse().matrix();
		Vector4f eyeVec4 = modelTransInv * Vector4f(0,0,1,0);
		Vector3f eyeVec3(eyeVec4.x(),eyeVec4.y(),eyeVec4.z());
        frameInfo.eyeVec = eyeVec3;
		
		// Snag the projection matrix so we can use it later
		Eigen::Matrix4f projMat;
		glGetFloatv(GL_PROJECTION_MATRIX,projMat.data());
		Mbr viewMbr(Point2f(-1,-1),Point2f(1,1));
		
		Vector4f test1(frustLL.x(),frustLL.y(),near,1.0);
		Vector4f test2(frustUR.x(),frustUR.y(),near,1.0);
		Vector4f projA = projMat * test1;
		Vector4f projB = projMat * test2;
		Vector3f projA_3(projA.x()/projA.w(),projA.y()/projA.w(),projA.z()/projA.w());
		Vector3f projB_3(projB.x()/projB.w(),projB.y()/projB.w(),projB.z()/projB.w());
        
        // Need an approximate MBR for the view
        // Note: This assumes we're working in geographic
        GeoMbr viewGeoMbr;
        WhirlyGlobeView *globeView = nil;
        if ([theView isKindOfClass:[WhirlyGlobeView class]])
        {
            globeView = (WhirlyGlobeView *)theView;
            viewGeoMbr = [self calcViewGeoMbr:globeView frameSize:Point2f(framebufferWidth,framebufferHeight) modelTrans:&modelTrans];
        }
		
		// Look through the cullables to assemble the set of drawables
		// We may encounter the same drawable multiple times, hence the std::set
        int drawablesConsidered = 0;
		std::set<const Drawable *> toDraw;
		unsigned int numX,numY;
		scene->getCullableSize(numX,numY);
		const Cullable *cullables = scene->getCullables();
		for (unsigned int ci=0;ci<numX*numY;ci++)
		{
			// Check the four corners of the cullable to see if they're pointed away
            // But just for the globe case
			const Cullable *theCullable = &cullables[ci];
			bool inView = false;
            if (coordSys->isFlat())
            {
                inView = true;
            } else {
                for (unsigned int ii=0;ii<4;ii++)
                {
                    Vector3f norm = theCullable->cornerNorms[ii];
                    if (norm.dot(eyeVec3) > 0)
                    {
                        inView = true;
                        break;
                    }
                }
            }
			
			// Now project the corners onto the viewing plane and see if we overlap
			// This lets us catch things around the edges
			if (inView)
			{
				Mbr cullMbr;
				
				for (unsigned int ii=0;ii<4;ii++)
				{
					// Build up the MBR on the view plane
					Vector3f pt = theCullable->cornerPoints[ii];
					Vector4f projPt = projMat * (modelTrans * Vector4f(pt.x(),pt.y(),pt.z(),1.0));
					Vector3f projPt3(projPt.x()/projPt.w(),projPt.y()/projPt.w(),projPt.z()/projPt.w());
					cullMbr.addPoint(Point2f(projPt3.x(),projPt3.y()));
				}
				
				if (!cullMbr.overlaps(viewMbr))
				{
					inView = false;
				}
			}
			
			if (inView)
			{
				const std::set<Drawable *> &theseDrawables = theCullable->getDrawables();
                for (std::set<Drawable *>::const_iterator it = theseDrawables.begin();
                     it != theseDrawables.end(); ++it)
                {
                    Drawable *drawable = *it;
                    if (drawable->isOn(frameInfo) && (!viewGeoMbr.valid() || drawable->getGeoMbr().overlaps(viewGeoMbr)))
                        toDraw.insert(drawable);
                    drawablesConsidered++;
                }
			}
		}
        
        // Turn these drawables in to a vector
		std::vector<const Drawable *> drawList;
		drawList.reserve(toDraw.size());
		for (std::set<const Drawable *>::iterator it = toDraw.begin();
			 it != toDraw.end(); ++it)
			drawList.push_back(*it);

        if (perfInterval > 0)
            perfTimer.stopTiming("Culling");
        
        if (perfInterval > 0)
            perfTimer.startTiming("Generators - 3D");

        // Now ask our generators to make their drawables
        // Note: Not doing any culling here
        //       And we should reuse these Drawables
        std::vector<Drawable *> generatedDrawables,screenDrawables;
        const GeneratorSet *generators = scene->getGenerators();
        for (GeneratorSet::iterator it = generators->begin();
             it != generators->end(); ++it)
            (*it)->generateDrawables(frameInfo, generatedDrawables, screenDrawables);
        
        // Add the generated drawables and sort them all together
        drawList.insert(drawList.end(), generatedDrawables.begin(), generatedDrawables.end());
        drawListSortStruct sortStruct;
        sortStruct.frameInfo = frameInfo;
		std::sort(drawList.begin(),drawList.end(),sortStruct);
        
        if (perfInterval > 0)
            perfTimer.addCount("Drawables considered", drawablesConsidered);
        
        if (perfInterval > 0)
            perfTimer.stopTiming("Generators - 3D");
        
        if (perfInterval > 0)
            perfTimer.startTiming("Draw Execution");
		
        bool depthMaskOn = zBuffer;
		for (unsigned int ii=0;ii<drawList.size();ii++)
		{
			const Drawable *drawable = drawList[ii];
            // The first time we hit an explicitly alpha drawable
            //  turn off the depth buffer
            if (depthMaskOn && drawable->hasAlpha(frameInfo))
            {
                depthMaskOn = false;
                glDisable(GL_DEPTH_TEST);
            }
            drawable->draw(frameInfo,scene);	
            numDrawables++;
		}
        
        if (perfInterval > 0)
            perfTimer.addCount("Drawables drawn", numDrawables);

        if (perfInterval > 0)
            perfTimer.stopTiming("Draw Execution");
        
        // Anything generated needs to be cleaned up
        // Note: Should have the generators keep them
        for (unsigned int ig=0;ig<generatedDrawables.size();ig++)
        {
            delete generatedDrawables[ig];
        }
        generatedDrawables.clear();
        drawList.clear();        
        
        if (perfInterval > 0)
            perfTimer.startTiming("Generators - 2D");

        // Now for the 2D display
        if (!screenDrawables.empty())
        {
            glDisable(GL_DEPTH_TEST);
            // Sort by draw priority (and alpha, I guess)
            drawList.insert(drawList.end(), screenDrawables.begin(), screenDrawables.end());
            drawListSortStruct sortStruct;
            sortStruct.frameInfo = frameInfo;
            std::sort(drawList.begin(),drawList.end(),sortStruct);
            
            // Set up the matrix
            glMatrixMode(GL_PROJECTION);
            glLoadIdentity();
            glOrthof(0, framebufferWidth, framebufferHeight, 0, -1, 1);
            glMatrixMode(GL_MODELVIEW);
            glLoadIdentity();
            // Move things over just a bit to get better sampling
            glTranslatef(0.375, 0.375, 0);
            
            for (unsigned int ii=0;ii<drawList.size();ii++)
            {
                const Drawable *drawable = drawList[ii];
                if (drawable->isOn(frameInfo))
                {
                    drawable->draw(frameInfo,scene);
                    numDrawables++;
                }
            }
            
            for (unsigned int ig=0;ig<screenDrawables.size();ig++)
                delete screenDrawables[ig];
            screenDrawables.clear();
            drawList.clear();
        }

        if (perfInterval > 0)
            perfTimer.stopTiming("Generators - 2D");
    }
    
    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    [context presentRenderbuffer:GL_RENDERBUFFER];
    
    // Call the pre-frame callback
    if (delegate && [(NSObject *)delegate respondsToSelector:@selector(postFrame:)])
        [delegate postFrame:self]; 
        
    if (perfInterval > 0)
        perfTimer.stopTiming("Render");    

	// Update the frames per sec
	if (perfInterval > 0 && frameCount++ > perfInterval)
	{
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
		NSTimeInterval howLong =  now - frameCountStart;;
		framesPerSec = frameCount / howLong;
		frameCountStart = now;
		frameCount = 0;
        
        NSLog(@"---Rendering Performance---");
        perfTimer.log();
        perfTimer.clear();
	}
}

@end
