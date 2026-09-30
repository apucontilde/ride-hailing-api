package handler

import (
	"errors"
	"log"
	"net/http"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

type DriverHandler struct {
	userRepo repository.UserRepository
	// geoRepo is used only to re-arm the dispatch liveness window when a status
	// write asks for "online". It is optional: a nil geoRepo disables the
	// refresh rather than failing the status update, so the handler stays
	// constructible in tests and in any future wiring that has no geo store.
	geoRepo repository.GeoRepository
}

// NewDriverHandlerWithGeo wires the presence refresh. The only constructor:
// without it a driver going online stays invisible to dispatch until they next
// publish a position fix.
func NewDriverHandlerWithGeo(userRepo repository.UserRepository, geoRepo repository.GeoRepository) *DriverHandler {
	return &DriverHandler{userRepo: userRepo, geoRepo: geoRepo}
}

type updateDriverRequest struct {
	FirstName string `json:"first_name"`
	LastName  string `json:"last_name"`
	PhotoURL  string `json:"photo_url"`
}

// Register godoc
//
//	@Summary		Register the authenticated user as a driver
//	@Description	Promotes the current user to the driver role and creates a driver profile.
//	@Tags			driver
//	@Produce		json
//	@Security		BearerAuth
//	@Success		201	{object}	DriverResponse
//	@Router			/api/v1/driver/register [post]
func (h *DriverHandler) Register(c *gin.Context) {
	userID, _ := c.Get("user_id")

	user, err := h.userRepo.FindByID(userID.(string))
	if err != nil {
		respondRepo(c, err, "user not found", "", "failed to load user")
		return
	}
	user.Role = "driver"
	if err := h.userRepo.UpdateUser(user); err != nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to update user role", err)
		return
	}

	driver := &model.Driver{
		UserID:           user.ID,
		Status:           "offline",
		OnboardingStatus: "documents_submitted",
	}
	if err := h.userRepo.CreateDriver(driver); err != nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to create driver profile", err)
		return
	}

	c.JSON(http.StatusCreated, gin.H{"driver": driver})
}

// GetProfile godoc
//
//	@Summary	Get the driver profile
//	@Tags		driver
//	@Produce	json
//	@Security	BearerAuth
//	@Success	200	{object}	DriverResponse
//	@Failure	404	{object}	ErrorResponse	"Driver not found"
//	@Router		/api/v1/driver/me [get]
func (h *DriverHandler) GetProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	driver, err := h.userRepo.FindDriverByID(userID.(string))
	if err != nil {
		respondRepo(c, err, "driver not found", "", "failed to load driver")
		return
	}
	c.JSON(http.StatusOK, gin.H{"driver": driver})
}

// UpdateProfile godoc
//
//	@Summary	Update the driver profile
//	@Tags		driver
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		updateDriverRequest	true	"Profile fields to update"
//	@Success	200		{object}	DriverResponse
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/driver/me [put]
func (h *DriverHandler) UpdateProfile(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var body updateDriverRequest
	if !bindJSON(c, &body, "") {
		return
	}

	driver, err := h.userRepo.FindDriverByID(userID.(string))
	if err != nil {
		respondRepo(c, err, "driver not found", "", "failed to load driver")
		return
	}
	driver.FirstName = body.FirstName
	driver.LastName = body.LastName
	driver.PhotoURL = body.PhotoURL
	if err := h.userRepo.UpdateDriver(driver); err != nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to update driver profile", err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"driver": driver})
}

// UpdateStatus godoc
//
//	@Summary	Update the driver availability status
//	@Tags		driver
//	@Accept		json
//	@Produce	json
//	@Security	BearerAuth
//	@Param		body	body		updateStatusRequest	true	"New status (e.g. online, offline)"
//	@Success	200		{object}	DriverResponse
//	@Failure	422		{object}	ErrorResponse	"Validation error"
//	@Router		/api/v1/driver/me/status [put]
func (h *DriverHandler) UpdateStatus(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var body updateStatusRequest
	if !bindJSON(c, &body, "") {
		return
	}

	driver, err := h.userRepo.FindDriverByID(userID.(string))
	if err != nil {
		respondRepo(c, err, "driver not found", "", "failed to load driver")
		return
	}
	driver.Status = body.Status
	if err := h.userRepo.UpdateDriver(driver); err != nil {
		fail(c, http.StatusInternalServerError, "INTERNAL", "failed to update driver status", err)
		return
	}

	// A status write of "online" also re-arms the dispatch liveness window on
	// the driver's LAST KNOWN position (api_plans [dispatch]).
	//
	// The dispatch search filters on `updated_at > NOW() - DriverLivenessWindow`,
	// so a driver who is online while stationary — or who opens the app again
	// after their last fix aged out — is invisible to dispatch until they next
	// move. That is the reported false negative: the driver is online in the app
	// and in the drivers table, the search says nobody is nearby, and the ride
	// ends in no_driver_available with no explanation. Touching the existing row
	// makes them eligible immediately.
	//
	// This is NOT a tracked state machine: the check is stateless — it reads
	// the status the request ASKED for, not the driver's previous one. A repeat
	// "online" write therefore refreshes again, which is harmless, and nothing
	// here depends on having observed the driver go offline first.
	//
	// TouchDriverPresence never invents coordinates and never resurrects an
	// arbitrarily old fix (repository.DriverPresenceMaxAgeS): it re-arms the
	// window on a FRESH position only. That is deliberate both ways — a driver's
	// last remembered coordinates are reused, but a fix from hours ago is not
	// "where they are", and re-arming it would hand a rider a wrong ETA.
	//
	// This is deliberately a SIDE EFFECT of a request whose own write already
	// succeeded, and the invariants are held explicitly:
	//   - A driver with no dispatchable position — no row at all, or one older
	//     than repository.DriverPresenceMaxAgeS — is a legitimate case, reported
	//     by the repository as ErrNotFound. That is recorded, not fatal: there is
	//     nothing to dispatch to, and 500-ing a valid status change would be a
	//     worse lie.
	//   - A real error (database down) is attached with c.Error so gin's
	//     middleware logs the cause, while the response stays 200 for the write
	//     that genuinely committed. Misreporting the response would break the
	//     unchanged-success-path invariant; swallowing the cause entirely would
	//     lose it. The only observable difference is in server logs.
	// The failure mode this must never become: answering 200 while a driver who
	// believes they are online is silently undispatchable. Hence the explicit
	// log line, which is the signal a support trace greps for.
	if h.geoRepo != nil && body.Status == "online" {
		if err := h.geoRepo.TouchDriverPresence(userID.(string), body.Status); err != nil {
			if errors.Is(err, repository.ErrNotFound) {
				logPresenceNote(userID.(string), body.Status, "no_position_online",
					"driver is online without a dispatchable position (never sent a fix, or the last fix is "+
						"stale); invisible to dispatch until the app pushes a fresh one")
			} else {
				logPresenceNote(userID.(string), body.Status, "presence_refresh_failed",
					"driver status write committed but the dispatch liveness refresh did not")
				_ = c.Error(err)
			}
		}
	}

	c.JSON(http.StatusOK, gin.H{"driver": driver})
}

// logPresenceNote records the named, greppable event behind the going-online
// presence refresh so "the driver says online but dispatch cannot see them" is
// a first-class signal in the logs rather than an invisible false negative.
func logPresenceNote(driverID, status, reason, detail string) {
	log.Printf("[dispatch] driver=%s status=%s reason=%s: %s", driverID, status, reason, detail)
}
